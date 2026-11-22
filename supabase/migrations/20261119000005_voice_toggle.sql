-- Voice notes are switched OFF by default. While off:
--   * oral tasks are reported with Done / Partial / Not done like any other task,
--   * submit_voice_report is refused,
--   * the app hides recording, the Reflections tab and the voice-sharing consent box.
-- To switch voice notes on later:  update public.settings set voice_notes_enabled = true;

alter table public.settings add column if not exists voice_notes_enabled boolean not null default false;

-- Readable by visitors too, so the registration page can show the right consent boxes.
create or replace function public.voice_notes_enabled() returns boolean
language sql stable security definer set search_path = '' as $$
  select s.voice_notes_enabled from public.settings s;
$$;
revoke execute on function public.voice_notes_enabled() from public;
grant execute on function public.voice_notes_enabled() to anon, authenticated;

create or replace function public.submit_report(p_daily_task_id uuid, p_status public.report_status)
returns void language plpgsql security definer set search_path = '' as $$
declare d public.daily_tasks; md public.member_days; n int; voice_on boolean;
begin
  select s.voice_notes_enabled into voice_on from public.settings s;
  select * into d from public.daily_tasks where id = p_daily_task_id;
  if not found then raise exception 'Task not found'; end if;
  select * into md from public.member_days
   where user_id = auth.uid() and day_date = d.day_date and level = d.level;
  if not found then raise exception 'This task is not assigned to you' using errcode = '42501'; end if;
  if d.is_oral and voice_on then raise exception 'Oral tasks are reported with a voice note'; end if;
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

create or replace function public.submit_voice_report(
  p_daily_task_id uuid, p_storage_path text, p_mime_type text, p_duration_seconds int, p_size_bytes int)
returns uuid language plpgsql security definer set search_path = '' as $$
declare d public.daily_tasks; md public.member_days; s public.settings; vid uuid; n int;
begin
  select * into s from public.settings;
  if not s.voice_notes_enabled then raise exception 'Voice notes are not switched on yet'; end if;
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
