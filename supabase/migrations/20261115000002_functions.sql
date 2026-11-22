-- Light Growth Academy: business rules (spec section 8), RPCs and the sweep job.
-- Conventions
--   * Internal jobs: SECURITY DEFINER, execute revoked from API roles (see 0003).
--   * User RPCs: SECURITY DEFINER, check the caller's role inside the function.
--   * Pure calculators and live-score helpers are SECURITY INVOKER so RLS applies.

-- ================================================================ role helpers
create or replace function public.is_active_user() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = auth.uid() and p.status = 'active');
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.status = 'active' and 'admin' = any (p.roles));
$$;

create or replace function public.is_mentor() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
                 where p.id = auth.uid() and p.status = 'active' and 'mentor' = any (p.roles));
$$;

create or replace function public.is_mentor_of(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1
                 from public.profiles me
                 join public.profiles m on m.mentor_id = me.id
                 where me.id = auth.uid() and me.status = 'active' and 'mentor' = any (me.roles)
                   and m.id = p_user);
$$;

create or replace function public.is_buddy_of(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p
                 where p.id = p_user and p.buddy_id = auth.uid())
     and public.is_active_user();
$$;

-- ================================================================ calculators (spec 8.1 - 8.4)
create or replace function public.community_today() returns date
language sql stable set search_path = '' as $$
  select (now() at time zone (select s.community_tz from public.settings s))::date;
$$;

-- 8.1: Done = 100, Partial = settings.partial_value (default 50), Not done = 0
create or replace function public.status_value(p_status public.report_status) returns numeric
language sql stable set search_path = '' as $$
  select case p_status
           when 'done'    then 100::numeric
           when 'partial' then (select s.partial_value from public.settings s)::numeric
           else 0::numeric
         end;
$$;

-- 8.3: bands on the score rounded to a whole number
create or replace function public.daily_band(p_score numeric) returns text
language sql immutable set search_path = '' as $$
  select case
           when p_score is null          then null
           when round(p_score) >= 80     then '80-100'
           when round(p_score) >= 60     then '60-79'
           when round(p_score) >= 45     then '45-59'
           when round(p_score) >= 20     then '20-44'
           else '0-19'
         end;
$$;

-- 8.4: weekly grade (rounded to a whole number first, same convention as bands; confirm with client)
create or replace function public.weekly_grade(p_avg numeric) returns text
language sql immutable set search_path = '' as $$
  select case
           when p_avg is null        then null
           when round(p_avg) >= 70   then 'Growing'
           when round(p_avg) >= 55   then 'Getting there'
           when round(p_avg) >= 40   then 'Struggling'
           else 'Not growing'
         end;
$$;

-- 8.2: average of every task assigned to the member's level that day, equal weights.
-- Unreported tasks count as 0 (the prototype shows 0% before anything is reported).
create or replace function public.live_day_score(p_user uuid, p_day date) returns numeric
language sql stable set search_path = '' as $$
  select round(avg(case when r.id is null then 0::numeric else public.status_value(r.status) end), 2)
  from public.member_days md
  join public.daily_tasks d on d.day_date = md.day_date and d.level = md.level
  left join public.task_reports r on r.daily_task_id = d.id and r.user_id = md.user_id
  where md.user_id = p_user and md.day_date = p_day;
$$;

create or replace function public.week_avg(p_user uuid, p_ref date) returns numeric
language sql stable set search_path = '' as $$
  select round(avg(coalesce(md.score, public.live_day_score(md.user_id, md.day_date))), 2)
  from public.member_days md
  where md.user_id = p_user
    and date_trunc('week', md.day_date::timestamp) = date_trunc('week', p_ref::timestamp);
$$;

-- ================================================================ internal helpers
create or replace function public.log_audit(p_action text, p_entity text, p_entity_id text, p_details jsonb default '{}')
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_log (actor, action, entity, entity_id, details)
  values (auth.uid(), p_action, p_entity, p_entity_id, coalesce(p_details, '{}'::jsonb));
$$;

-- Queue one notification per allowed channel. WhatsApp needs the latest 'reminders' consent = granted.
create or replace function public.enqueue_notification(p_user uuid, p_key text, p_payload jsonb, p_dedupe text)
returns void language sql security definer set search_path = '' as $$
  insert into public.notifications (user_id, channel, template_key, payload, status, dedupe_key)
  select p.id, v.channel, p_key, coalesce(p_payload, '{}'::jsonb),
         (case when v.channel = 'in_app' then 'delivered' else 'queued' end)::public.notify_status,
         p_dedupe
  from public.profiles p
  cross join lateral (values
    ('email'::public.notify_channel,    p.notify_email),
    ('whatsapp'::public.notify_channel, p.notify_whatsapp and p.phone is not null and coalesce(
        (select c.granted from public.consents c
          where c.user_id = p.id and c.consent_type = 'reminders'
          order by c.created_at desc, c.id desc limit 1), false)),
    ('in_app'::public.notify_channel,   true)
  ) as v(channel, allowed)
  where p.id = p_user and v.allowed
  on conflict do nothing;
$$;

create or replace function public.missed_streak(p_user uuid, p_through date default null) returns int
language plpgsql stable security definer set search_path = '' as $$
declare n int := 0; r record;
begin
  for r in
    select md.reported_any from public.member_days md
    where md.user_id = p_user and md.closed_at is not null
      and (p_through is null or md.day_date <= p_through)
    order by md.day_date desc
  loop
    exit when r.reported_any;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.in_local_window(p_now timestamptz, p_tz text, p_at time, p_minutes int)
returns boolean language sql stable set search_path = '' as $$
  select exists (
    select 1 from generate_series(-1, 0) g
    where (p_now at time zone p_tz) >= date_trunc('day', p_now at time zone p_tz) + g * interval '1 day' + p_at
      and (p_now at time zone p_tz) <  date_trunc('day', p_now at time zone p_tz) + g * interval '1 day' + p_at
                                       + make_interval(mins => p_minutes)
  );
$$;

-- ================================================================ signup / profile triggers
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  m  jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  tz text  := coalesce(nullif(m->>'time_zone', ''), 'Africa/Lagos');
  pv text  := coalesce(nullif(m->>'policy_version', ''), 'v1');
  k  text;
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = tz) then
    tz := 'Africa/Lagos';
  end if;
  insert into public.profiles (id, full_name, email, phone, country, time_zone, referral_source, status)
  values (new.id,
          coalesce(nullif(btrim(m->>'full_name'), ''), split_part(new.email, '@', 1)),
          new.email, nullif(m->>'phone', ''), nullif(m->>'country', ''), tz,
          nullif(m->>'referral_source', ''), 'pending');
  foreach k in array array['terms_privacy', 'data_sharing', 'reminders', 'voice_sharing'] loop
    if (m->'consents'->>k) = 'true' then
      insert into public.consents (user_id, consent_type, policy_version, granted)
      values (new.id, k, pv, true);
    end if;
  end loop;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Auto-approval mode: activate once the email is verified.
create or replace function public.handle_email_confirmed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if old.email_confirmed_at is null and new.email_confirmed_at is not null
     and (select s.approval_mode from public.settings s) = 'auto' then
    update public.profiles set status = 'active', level_since = current_date
     where id = new.id and status = 'pending';
  end if;
  return new;
end $$;

create trigger on_auth_user_confirmed
  after update of email_confirmed_at on auth.users
  for each row execute function public.handle_email_confirmed();

-- Members may edit their own profile, but never role/status/level/mentor/buddy/email.
create or replace function public.protect_profile_columns() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if new.id <> old.id
       or new.roles is distinct from old.roles
       or new.status is distinct from old.status
       or new.level is distinct from old.level
       or new.level_since is distinct from old.level_since
       or new.mentor_id is distinct from old.mentor_id
       or new.buddy_id is distinct from old.buddy_id
       or new.email is distinct from old.email then
      raise exception 'Protected profile fields can only be changed by an admin' using errcode = '42501';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger profiles_protect
  before update on public.profiles
  for each row execute function public.protect_profile_columns();

-- Generic audit trigger for admin edits made straight through RLS.
create or replace function public.audit_row_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare j_old jsonb; j_new jsonb;
begin
  if auth.uid() is not null and public.is_admin() then
    j_old := case when tg_op <> 'INSERT' then to_jsonb(old) end;
    j_new := case when tg_op <> 'DELETE' then to_jsonb(new) end;
    insert into public.audit_log (actor, action, entity, entity_id, details)
    values (auth.uid(), lower(tg_op), tg_table_name,
            coalesce(j_new->>'id', j_new->>'key', j_new->>'level', j_old->>'id', j_old->>'key', j_old->>'level'),
            jsonb_build_object('old', j_old, 'new', j_new));
  end if;
  return coalesce(new, old);
end $$;

create trigger audit_tasks        after insert or update or delete on public.tasks        for each row execute function public.audit_row_change();
create trigger audit_books        after insert or update or delete on public.books        for each row execute function public.audit_row_change();
create trigger audit_sermons      after insert or update or delete on public.sermons      for each row execute function public.audit_row_change();
create trigger audit_page_content after insert or update or delete on public.page_content for each row execute function public.audit_row_change();
create trigger audit_settings     after insert or update or delete on public.settings     for each row execute function public.audit_row_change();
create trigger audit_levels       after insert or update or delete on public.levels       for each row execute function public.audit_row_change();

-- ================================================================ daily lifecycle (internal)
-- Snapshot the tasks due on a date. Idempotent. Never touches tasks that already have reports.
create or replace function public.materialize_daily_tasks(p_day date) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.daily_tasks (task_id, level, day_date, title, is_oral, sort_order)
  select t.id, t.level, p_day, t.title, t.is_oral, t.sort_order
  from public.tasks t
  where not t.archived
    and t.start_date <= p_day
    and (t.end_date is null or t.end_date >= p_day)
    and (t.recurrence = 'daily' or (p_day - t.start_date) % 14 = 0)
  on conflict (task_id, day_date) do update
    set title = excluded.title, is_oral = excluded.is_oral,
        sort_order = excluded.sort_order, level = excluded.level
    where not exists (select 1 from public.task_reports r where r.daily_task_id = public.daily_tasks.id);

  delete from public.daily_tasks d
  where d.day_date = p_day
    and not exists (select 1 from public.task_reports r where r.daily_task_id = d.id)
    and (d.task_id is null or not exists (
          select 1 from public.tasks t
          where t.id = d.task_id and not t.archived
            and t.start_date <= p_day and (t.end_date is null or t.end_date >= p_day)
            and (t.recurrence = 'daily' or (p_day - t.start_date) % 14 = 0)));
end $$;

-- Create member_days for everyone whose level has tasks on p_day. Only while the day is open.
create or replace function public.open_day(p_day date) returns int
language plpgsql security definer set search_path = '' as $$
declare s public.settings; rel timestamptz; n int;
begin
  select * into s from public.settings;
  rel := ((p_day + s.release_time)::timestamp at time zone s.community_tz);
  if now() < rel or now() >= rel + interval '24 hours' then
    return 0;
  end if;
  perform public.materialize_daily_tasks(p_day);
  insert into public.member_days (user_id, day_date, level, release_at, deadline_at)
  select p.id, p_day, p.level, rel, rel + interval '24 hours'
  from public.profiles p
  where p.status = 'active' and 'member' = any (p.roles)
    and exists (select 1 from public.daily_tasks d where d.day_date = p_day and d.level = p.level)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.recompute_member_day(p_user uuid, p_day date) returns void
language sql security definer set search_path = '' as $$
  update public.member_days
     set score = public.live_day_score(p_user, p_day)
   where user_id = p_user and day_date = p_day and closed_at is not null;
$$;

-- 8.7: first missed day alerts buddy + mentor; the third in a row is a red alert (buddy, mentor, admins).
create or replace function public.register_missed_day(p_user uuid, p_day date) returns void
language plpgsql security definer set search_path = '' as $$
declare
  streak int; k public.alert_kind; m public.profiles; payload jsonb; tkey text;
begin
  streak := public.missed_streak(p_user, p_day);
  if    streak = 1 then k := 'missed_day';
  elsif streak = 3 then k := 'red_alert';
  else  return;
  end if;

  insert into public.alerts (user_id, kind, day_date, streak)
  values (p_user, k, p_day, streak) on conflict do nothing;
  if not found then return; end if;

  select * into m from public.profiles where id = p_user;
  tkey    := k::text;
  payload := jsonb_build_object('member_name', m.full_name, 'day', p_day, 'streak', streak);

  perform public.enqueue_notification(r, tkey, payload, tkey || ':' || p_user || ':' || p_day)
    from unnest(array[m.buddy_id, m.mentor_id]) as r where r is not null;

  if k = 'red_alert' then
    perform public.enqueue_notification(a.id, tkey, payload, tkey || ':' || p_user || ':' || p_day)
      from public.profiles a where a.status = 'active' and 'admin' = any (a.roles);
  end if;
end $$;

-- 8.6: after the deadline every unreported task becomes Not done automatically.
create or replace function public.close_expired_days() returns int
language plpgsql security definer set search_path = '' as $$
declare md record; n int := 0; any_reported boolean;
begin
  for md in
    select * from public.member_days
    where closed_at is null and deadline_at <= now()
    order by day_date
    for update skip locked
  loop
    select exists (select 1 from public.task_reports r
                   where r.user_id = md.user_id and r.day_date = md.day_date)
      into any_reported;

    insert into public.task_reports (daily_task_id, user_id, day_date, status, source)
    select d.id, md.user_id, md.day_date, 'not_done'::public.report_status, 'auto_deadline'::public.report_source
    from public.daily_tasks d
    where d.day_date = md.day_date and d.level = md.level
    on conflict (daily_task_id, user_id) do nothing;

    update public.member_days
       set closed_at = now(),
           reported_any = any_reported,
           score = public.live_day_score(md.user_id, md.day_date)
     where user_id = md.user_id and day_date = md.day_date;

    if not any_reported then
      perform public.register_missed_day(md.user_id, md.day_date);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- Two reminders per day (spec 9). Times follow the member's own time zone. Deduped per day.
create or replace function public.enqueue_due_reminders() returns void
language plpgsql security definer set search_path = '' as $$
declare s public.settings; rec record; second_at time;
begin
  select * into s from public.settings;
  for rec in
    select p.id as user_id, p.time_zone, p.reminder_time, md.day_date, md.deadline_at,
           (select count(*) from public.daily_tasks d
             where d.day_date = md.day_date and d.level = md.level
               and not exists (select 1 from public.task_reports r
                                where r.daily_task_id = d.id and r.user_id = p.id)) as remaining
    from public.profiles p
    join public.member_days md
      on md.user_id = p.id and md.closed_at is null
     and md.release_at <= now() and md.deadline_at > now()
    where p.status = 'active'
  loop
    continue when rec.remaining = 0;
    second_at := case when rec.reminder_time >= time '18:00' or rec.reminder_time < time '05:00'
                      then time '07:00' else s.default_second_reminder end;

    if public.in_local_window(now(), rec.time_zone, rec.reminder_time, 30) then
      perform public.enqueue_notification(rec.user_id, 'reminder',
        jsonb_build_object('which', 'first', 'remaining', rec.remaining,
                           'hours_left', round(extract(epoch from rec.deadline_at - now()) / 3600, 1)),
        'reminder1:' || rec.day_date);
    end if;
    if public.in_local_window(now(), rec.time_zone, second_at, 30) then
      perform public.enqueue_notification(rec.user_id, 'reminder',
        jsonb_build_object('which', 'second', 'remaining', rec.remaining,
                           'hours_left', round(extract(epoch from rec.deadline_at - now()) / 3600, 1)),
        'reminder2:' || rec.day_date);
    end if;
  end loop;
end $$;

-- ================================================================ level reviews (spec 8.5)
-- Qualifies when Growing (monthly avg >= threshold) in at least 2 of the 3 calendar months before
-- the review date (this also covers "all 3"). Level 4 is the ceiling. Never demotes.
create or replace function public.build_level_review(p_date date) returns uuid
language plpgsql security definer set search_path = '' as $$
declare rid uuid; s public.settings;
begin
  select * into s from public.settings;
  insert into public.level_reviews (review_date) values (p_date)
  on conflict (review_date) do nothing returning id into rid;
  if rid is null then
    select id into rid from public.level_reviews where review_date = p_date;
    return rid;
  end if;

  insert into public.level_review_items (review_id, user_id, from_level, to_level, growing_months, month_averages)
  select rid, p.id, p.level, p.level + 1, m.growing, m.avgs
  from public.profiles p
  cross join lateral (
    select count(*) filter (where a.avg_score >= s.growing_threshold)::int as growing,
           coalesce(jsonb_object_agg(to_char(a.month_start, 'YYYY-MM'), a.avg_score), '{}'::jsonb) as avgs
    from (
      select date_trunc('month', md.day_date)::date as month_start, round(avg(md.score), 2) as avg_score
      from public.member_days md
      where md.user_id = p.id and md.score is not null
        and md.day_date >= (date_trunc('month', p_date::timestamp) - interval '3 months')::date
        and md.day_date <  date_trunc('month', p_date::timestamp)::date
      group by 1
    ) a
  ) m
  where p.status = 'active' and 'member' = any (p.roles) and p.level < 4 and m.growing >= 2;
  return rid;
end $$;

create or replace function public.prepare_due_level_review() returns void
language plpgsql security definer set search_path = '' as $$
declare s public.settings; d date;
begin
  select * into s from public.settings;
  d := public.community_today();
  if extract(month from d)::int = any (s.review_months) and extract(day from d)::int = s.review_day then
    perform public.build_level_review(d);
  end if;
end $$;

-- ================================================================ the sweep (called by pg_cron every 5 min)
create or replace function public.run_sweep() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d date; opened int; closed int; requeued int;
begin
  if not pg_try_advisory_xact_lock(727001) then
    return jsonb_build_object('skipped', true);
  end if;
  d := public.community_today();
  opened := public.open_day(d) + public.open_day(d - 1);
  closed := public.close_expired_days();
  perform public.enqueue_due_reminders();
  perform public.prepare_due_level_review();
  update public.notifications set status = 'queued'
   where status = 'sending' and claimed_at < now() - interval '10 minutes';
  get diagnostics requeued = row_count;
  return jsonb_build_object('at', now(), 'opened', opened, 'closed', closed, 'requeued', requeued);
end $$;

-- Dispatcher (Edge Function, service role) claims a batch; failures go back to 'queued' with backoff.
create or replace function public.claim_notifications(p_limit int default 50)
returns setof public.notifications
language sql security definer set search_path = '' as $$
  update public.notifications n
     set status = 'sending', attempts = n.attempts + 1, claimed_at = now()
   where n.id in (select q.id from public.notifications q
                   where q.status = 'queued' and q.channel <> 'in_app' and q.next_attempt_at <= now()
                   order by q.created_at limit p_limit for update skip locked)
  returning n.*;
$$;

-- ================================================================ member RPCs
-- Done / Partial / Not done for a normal (non-oral) task. Changeable until the deadline.
create or replace function public.submit_report(p_daily_task_id uuid, p_status public.report_status)
returns void language plpgsql security definer set search_path = '' as $$
declare d public.daily_tasks; md public.member_days; n int;
begin
  select * into d from public.daily_tasks where id = p_daily_task_id;
  if not found then raise exception 'Task not found'; end if;
  select * into md from public.member_days
   where user_id = auth.uid() and day_date = d.day_date and level = d.level;
  if not found then raise exception 'This task is not assigned to you' using errcode = '42501'; end if;
  if d.is_oral then raise exception 'Oral tasks are reported with a voice note'; end if;
  if md.closed_at is not null or now() >= md.deadline_at or now() < md.release_at then
    raise exception 'Reporting is closed for this day';
  end if;

  insert into public.task_reports as tr (daily_task_id, user_id, day_date, status, source)
  values (d.id, auth.uid(), d.day_date, p_status, 'member')
  on conflict (daily_task_id, user_id) do update
    set status = excluded.status, source = 'member', reported_at = now(), updated_at = now()
    where tr.source <> 'mentor_override';
  get diagnostics n = row_count;
  if n = 0 then raise exception 'This report was changed by your mentor and can no longer be edited'; end if;
end $$;

-- Oral task: file is already uploaded to voice-notes/<uid>/...; submitting counts as Done.
create or replace function public.submit_voice_report(
  p_daily_task_id uuid, p_storage_path text, p_mime_type text, p_duration_seconds int, p_size_bytes int)
returns uuid language plpgsql security definer set search_path = '' as $$
declare d public.daily_tasks; md public.member_days; s public.settings; vid uuid; n int;
begin
  select * into s from public.settings;
  select * into d from public.daily_tasks where id = p_daily_task_id;
  if not found then raise exception 'Task not found'; end if;
  select * into md from public.member_days
   where user_id = auth.uid() and day_date = d.day_date and level = d.level;
  if not found then raise exception 'This task is not assigned to you' using errcode = '42501'; end if;
  if not d.is_oral then raise exception 'This task does not take a voice note'; end if;
  if md.closed_at is not null or now() >= md.deadline_at or now() < md.release_at then
    raise exception 'Reporting is closed for this day';
  end if;
  if p_storage_path not like auth.uid()::text || '/%' then
    raise exception 'Invalid file path' using errcode = '42501';
  end if;
  if p_mime_type not like 'audio/%' then raise exception 'Only audio files are accepted'; end if;
  if p_duration_seconds is null or p_duration_seconds < 1 or p_duration_seconds > s.voice_max_seconds then
    raise exception 'Voice notes can be at most % seconds', s.voice_max_seconds;
  end if;
  if p_size_bytes is null or p_size_bytes < 1 or p_size_bytes > s.voice_max_bytes then
    raise exception 'The file is too large (max % MB)', s.voice_max_bytes / 1048576;
  end if;

  insert into public.voice_notes (user_id, day_date, storage_path, mime_type, duration_seconds, size_bytes)
  values (auth.uid(), d.day_date, p_storage_path, p_mime_type, p_duration_seconds, p_size_bytes)
  returning id into vid;

  insert into public.task_reports (daily_task_id, user_id, day_date, status, source, voice_note_id)
  values (d.id, auth.uid(), d.day_date, 'done', 'voice_note', vid)
  on conflict (daily_task_id, user_id) do nothing;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'This task has already been reported'; end if;
  return vid;
end $$;

create or replace function public.buddy_overview() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare b public.profiles; md public.member_days; wk numeric;
begin
  select bp.* into b
    from public.profiles me join public.profiles bp on bp.id = me.buddy_id
   where me.id = auth.uid() and me.status = 'active' and bp.status = 'active';
  if not found then return null; end if;

  select * into md from public.member_days
   where user_id = b.id and release_at <= now() order by day_date desc limit 1;
  wk := public.week_avg(b.id, public.community_today());

  -- Deliberately no override details: buddies only see effective statuses.
  return jsonb_build_object(
    'buddy_id', b.id, 'name', b.full_name, 'level', b.level, 'day', md.day_date,
    'today_score', case when md.user_id is null then null
                        else coalesce(md.score, public.live_day_score(md.user_id, md.day_date)) end,
    'week_avg', wk, 'week_grade', public.weekly_grade(wk),
    'tasks', coalesce((
        select jsonb_agg(jsonb_build_object('title', dt.title, 'is_oral', dt.is_oral, 'status', r.status)
                         order by dt.sort_order, dt.title)
        from public.daily_tasks dt
        left join public.task_reports r on r.daily_task_id = dt.id and r.user_id = b.id
        where dt.day_date = md.day_date and dt.level = md.level), '[]'::jsonb));
end $$;

create or replace function public.community_reflections(p_limit int default 30, p_before timestamptz default null)
returns table (note_id uuid, member_name text, member_level int, created_at timestamptz,
               storage_path text, duration_seconds int)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_active_user() then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
    select v.id, p.full_name, p.level, v.created_at, v.storage_path, v.duration_seconds
    from public.voice_notes v join public.profiles p on p.id = v.user_id
    where not v.hidden and (p_before is null or v.created_at < p_before)
    order by v.created_at desc
    limit least(greatest(p_limit, 1), 100);
end $$;

-- ================================================================ mentor RPCs
-- Own mentees by default. With the member's own switch (mentor_sees_all) other members appear too.
create or replace function public.mentor_dashboard()
returns table (member_id uuid, member_name text, member_level int, is_mine boolean,
               today_score numeric, week_avg numeric, week_grade text, missed_streak int)
language plpgsql stable security definer set search_path = '' as $$
declare me public.profiles;
begin
  select * into me from public.profiles
   where id = auth.uid() and status = 'active' and ('mentor' = any (roles) or 'admin' = any (roles));
  if not found then raise exception 'not allowed' using errcode = '42501'; end if;

  return query
    select p.id, p.full_name, p.level, (p.mentor_id = me.id), t.today, w.avg_w,
           public.weekly_grade(w.avg_w), public.missed_streak(p.id)
    from public.profiles p
    left join lateral (
      select coalesce(md.score, public.live_day_score(p.id, md.day_date)) as today
      from public.member_days md
      where md.user_id = p.id and md.release_at <= now()
      order by md.day_date desc limit 1) t on true
    left join lateral (select public.week_avg(p.id, public.community_today()) as avg_w) w on true
    where p.status = 'active' and 'member' = any (p.roles) and p.id <> me.id
      and (p.mentor_id = me.id or 'admin' = any (me.roles) or me.mentor_sees_all)
    order by (p.mentor_id = me.id) desc, p.full_name;
end $$;

-- 8.8: change a report (or set one that is "Not reported") with a compulsory reason.
create or replace function public.override_report(
  p_user uuid, p_daily_task_id uuid, p_status public.report_status, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare d public.daily_tasks; md public.member_days; r public.task_reports;
        had boolean; rid uuid; oid uuid; reason text := btrim(coalesce(p_reason, ''));
begin
  if not (public.is_admin() or public.is_mentor_of(p_user)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if length(reason) < 3 then raise exception 'A written reason is required'; end if;

  select * into d from public.daily_tasks where id = p_daily_task_id;
  if not found then raise exception 'Task not found'; end if;
  select * into md from public.member_days
   where user_id = p_user and day_date = d.day_date and level = d.level;
  if not found then raise exception 'This task was not assigned to that member'; end if;

  select * into r from public.task_reports where daily_task_id = p_daily_task_id and user_id = p_user for update;
  had := found;
  if had and r.status = p_status then raise exception 'The report already has that status'; end if;

  insert into public.task_reports (daily_task_id, user_id, day_date, status, source)
  values (d.id, p_user, d.day_date, p_status, 'mentor_override')
  on conflict (daily_task_id, user_id) do update
    set status = excluded.status, source = 'mentor_override', updated_at = now()
  returning id into rid;

  insert into public.overrides (report_id, user_id, day_date, mentor_id, from_status, from_source, to_status, reason)
  values (rid, p_user, d.day_date, auth.uid(),
          case when had then r.status end, case when had then r.source end, p_status, reason)
  returning id into oid;

  if md.closed_at is not null then perform public.recompute_member_day(p_user, d.day_date); end if;

  perform public.enqueue_notification(p_user, 'override_made',
    jsonb_build_object('task', d.title, 'new_status', p_status, 'reason', reason), 'override:' || oid);
  perform public.log_audit('override', 'task_report', rid::text,
    jsonb_build_object('override_id', oid, 'user_id', p_user, 'to', p_status, 'reason', reason));
  return oid;
end $$;

create or replace function public.extension_usage(p_day date default null)
returns table (used int, max_allowed int)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not (public.is_admin() or public.is_mentor()) then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
    select (select count(*)::int from public.extensions e where e.day_date = coalesce(p_day, public.community_today())),
           (select s.extension_limit from public.settings s);
end $$;

-- 8.6: each extension adds 24h; 3 per date in total (settings.extension_limit), whoever grants them.
-- The settings row lock serialises concurrent grants so the cap cannot be raced.
create or replace function public.grant_extension(
  p_scope public.extension_scope, p_day date default null, p_user uuid default null, p_note text default null)
returns int language plpgsql security definer set search_path = '' as $$
declare s public.settings; d date := coalesce(p_day, public.community_today());
        used int; targets uuid[]; eid bigint;
begin
  if not (public.is_admin() or public.is_mentor()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into s from public.settings for update;
  select count(*) into used from public.extensions where day_date = d;
  if used >= s.extension_limit then
    raise exception 'Extension limit reached: % of % already used for %', used, s.extension_limit, d
      using errcode = 'P0001';
  end if;

  if p_scope = 'member' then
    if p_user is null then raise exception 'A member is required'; end if;
    if not (public.is_admin() or public.is_mentor_of(p_user)) then
      raise exception 'not allowed' using errcode = '42501';
    end if;
    targets := array[p_user];
  elsif p_scope = 'mentees' then
    select array_agg(id) into targets from public.profiles where mentor_id = auth.uid();
  else
    if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
    select array_agg(user_id) into targets from public.member_days where day_date = d;
  end if;
  if targets is null then raise exception 'There is no one to extend for %', d; end if;

  insert into public.extensions (day_date, scope, target_user, granted_by, note)
  values (d, p_scope, case when p_scope = 'member' then p_user end, auth.uid(), p_note)
  returning id into eid;

  -- Days that already closed are re-opened: auto "Not done" rows are removed and the member gets 24h from now.
  delete from public.task_reports tr
   where tr.day_date = d and tr.user_id = any (targets) and tr.source = 'auto_deadline';
  update public.member_days
     set deadline_at = case when closed_at is not null then now() + interval '24 hours'
                            else deadline_at + interval '24 hours' end,
         extension_hours = extension_hours + 24,
         closed_at = null, score = null
   where day_date = d and user_id = any (targets);

  perform public.enqueue_notification(t, 'extension_granted', jsonb_build_object('day', d), 'ext:' || eid)
    from unnest(targets) as t;
  perform public.log_audit('extension', 'extensions', eid::text,
    jsonb_build_object('day', d, 'scope', p_scope, 'user', p_user));
  return s.extension_limit - used - 1;
end $$;

-- ================================================================ admin RPCs
create or replace function public.set_buddy(p_a uuid, p_b uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_a = p_b then raise exception 'A member cannot be their own buddy'; end if;
  update public.profiles set buddy_id = null
   where id in (p_a, p_b) or buddy_id in (p_a, p_b);
  update public.profiles set buddy_id = p_b where id = p_a;
  update public.profiles set buddy_id = p_a where id = p_b;
  perform public.log_audit('set_buddy', 'profiles', p_a::text, jsonb_build_object('buddy', p_b));
end $$;

create or replace function public.clear_buddy(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  update public.profiles set buddy_id = null where id = p_user or buddy_id = p_user;
  perform public.log_audit('clear_buddy', 'profiles', p_user::text, '{}');
end $$;

create or replace function public.approve_member(
  p_user uuid, p_level int default 1, p_mentor uuid default null, p_buddy uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if not exists (select 1 from auth.users u where u.id = p_user and u.email_confirmed_at is not null) then
    raise exception 'This member has not verified their email yet';
  end if;
  update public.profiles
     set status = 'active', level = p_level, level_since = current_date, mentor_id = p_mentor
   where id = p_user;
  if p_buddy is not null then perform public.set_buddy(p_user, p_buddy); end if;
  perform public.enqueue_notification(p_user, 'approved', '{}'::jsonb, 'approved:' || p_user);
  perform public.log_audit('approve_member', 'profiles', p_user::text,
    jsonb_build_object('level', p_level, 'mentor', p_mentor, 'buddy', p_buddy));
end $$;

create or replace function public.reject_member(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  update public.profiles set status = 'rejected' where id = p_user and status = 'pending';
  perform public.log_audit('reject_member', 'profiles', p_user::text, '{}');
end $$;

create or replace function public.reverse_override(p_override_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.overrides; day_open boolean;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into o from public.overrides where id = p_override_id for update;
  if not found then raise exception 'Override not found'; end if;
  if o.reversed_at is not null then raise exception 'This override was already reversed'; end if;
  if exists (select 1 from public.overrides x
              where x.report_id = o.report_id and x.created_at > o.created_at and x.reversed_at is null) then
    raise exception 'Reverse the newer override on this report first';
  end if;

  select exists (select 1 from public.member_days md
                  where md.user_id = o.user_id and md.day_date = o.day_date and md.closed_at is null)
    into day_open;

  if o.from_status is null then
    if day_open then
      delete from public.task_reports where id = o.report_id;
    else
      update public.task_reports set status = 'not_done', source = 'auto_deadline', updated_at = now()
       where id = o.report_id;
    end if;
  else
    update public.task_reports set status = o.from_status, source = o.from_source, updated_at = now()
     where id = o.report_id;
  end if;

  update public.overrides set reversed_at = now(), reversed_by = auth.uid() where id = o.id;
  perform public.recompute_member_day(o.user_id, o.day_date);
  perform public.log_audit('reverse_override', 'overrides', o.id::text, jsonb_build_object('user_id', o.user_id));
end $$;

create or replace function public.admin_resync_day(p_day date default null) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  perform public.materialize_daily_tasks(coalesce(p_day, public.community_today()));
end $$;

create or replace function public.admin_prepare_level_review(p_date date default null) returns uuid
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  return public.build_level_review(coalesce(p_date, public.community_today()));
end $$;

-- Approve or reject review items in one action (p_items null = every pending item in the review).
create or replace function public.decide_review_items(
  p_review uuid, p_approve boolean, p_items uuid[] default null)
returns int language plpgsql security definer set search_path = '' as $$
declare it record; n int := 0;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  for it in
    select * from public.level_review_items
     where review_id = p_review and decision = 'pending' and (p_items is null or id = any (p_items))
     for update
  loop
    if p_approve then
      update public.profiles set level = it.to_level, level_since = current_date where id = it.user_id;
      insert into public.level_history (user_id, from_level, to_level, reason, review_id, changed_by)
      values (it.user_id, it.from_level, it.to_level, 'review', p_review, auth.uid());
      perform public.enqueue_notification(it.user_id, 'level_review_result',
        jsonb_build_object('promoted', true, 'new_level', it.to_level), 'review:' || it.id);
    end if;
    update public.level_review_items
       set decision = case when p_approve then 'approved' else 'rejected' end::public.review_decision,
           decided_by = auth.uid(), decided_at = now()
     where id = it.id;
    n := n + 1;
  end loop;
  if not exists (select 1 from public.level_review_items where review_id = p_review and decision = 'pending') then
    update public.level_reviews set status = 'completed', completed_at = now() where id = p_review;
  end if;
  perform public.log_audit('decide_review', 'level_reviews', p_review::text,
    jsonb_build_object('approve', p_approve, 'count', n));
  return n;
end $$;

-- Manual reset: one member (p_user) or everyone (null), e.g. at year end. The only way a level goes down.
create or replace function public.reset_levels(p_user uuid default null, p_to int default 1) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  insert into public.level_history (user_id, from_level, to_level, reason, changed_by)
  select p.id, p.level, p_to, 'reset', auth.uid()
    from public.profiles p
   where (p_user is null or p.id = p_user) and 'member' = any (p.roles) and p.level <> p_to;
  update public.profiles set level = p_to, level_since = current_date
   where (p_user is null or id = p_user) and 'member' = any (roles) and level <> p_to;
  get diagnostics n = row_count;
  perform public.log_audit('reset_levels', 'profiles', coalesce(p_user::text, 'all'), jsonb_build_object('to', p_to));
  return n;
end $$;

create or replace function public.admin_overview() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare cur date;
begin
  if not public.is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  select max(md.day_date) into cur from public.member_days md where md.release_at <= now();
  return jsonb_build_object(
    'active_members',  (select count(*) from public.profiles where status = 'active'),
    'pending_members', (select count(*) from public.profiles where status = 'pending'),
    'reported_today',  (select count(distinct r.user_id) from public.task_reports r
                         where r.day_date = cur and r.source <> 'auto_deadline'),
    'avg_week_score',  (select round(avg(coalesce(md.score, public.live_day_score(md.user_id, md.day_date))), 1)
                          from public.member_days md
                         where date_trunc('week', md.day_date::timestamp)
                             = date_trunc('week', public.community_today()::timestamp)),
    'red_alerts_7d',   (select count(distinct a.user_id) from public.alerts a
                         where a.kind = 'red_alert' and a.created_at > now() - interval '7 days'));
end $$;

-- ================================================================ resources
-- Gate for the Next.js download route: returns the file path if the caller may download it
-- and bumps the counter. The route then creates a signed URL with the service role.
create or replace function public.record_download(p_book uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare b public.books;
begin
  select * into b from public.books where id = p_book and visible;
  if not found then raise exception 'Not found' using errcode = 'P0002'; end if;
  if b.access = 'members' and not public.is_active_user() then
    raise exception 'This resource is for members only' using errcode = '42501';
  end if;
  update public.books set download_count = download_count + 1 where id = p_book;
  return b.file_path;
end $$;

-- ================================================================ views (RLS applies via security_invoker)
create view public.weekly_scores with (security_invoker = true) as
select md.user_id,
       date_trunc('week', md.day_date::timestamp)::date as week_start,
       round(avg(coalesce(md.score, public.live_day_score(md.user_id, md.day_date))), 2) as avg_score,
       public.weekly_grade(avg(coalesce(md.score, public.live_day_score(md.user_id, md.day_date)))) as grade,
       count(*)::int as days_counted
from public.member_days md
group by 1, 2;

create view public.monthly_scores with (security_invoker = true) as
select md.user_id,
       date_trunc('month', md.day_date::timestamp)::date as month_start,
       round(avg(coalesce(md.score, public.live_day_score(md.user_id, md.day_date))), 2) as avg_score,
       avg(coalesce(md.score, public.live_day_score(md.user_id, md.day_date)))
         >= (select s.growing_threshold from public.settings s) as growing,
       count(*)::int as days_counted
from public.member_days md
group by 1, 2;
