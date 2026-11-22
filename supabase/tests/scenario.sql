-- End-to-end scenario for the Light Growth Academy rules (spec sections 8, 10, 16).
-- Run against a scratch database after migrations + seed:
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -f supabase/tests/scenario.sql
-- Everything runs in one transaction and is rolled back at the end.
-- Needs the Supabase roles (authenticated) and auth.users; on plain Postgres use stub schemas.

\set ON_ERROR_STOP on
\set admin  '''aaaaaaaa-0000-0000-0000-000000000001'''
\set mentor '''aaaaaaaa-0000-0000-0000-000000000002'''
\set grace  '''aaaaaaaa-0000-0000-0000-000000000003'''
\set daniel '''aaaaaaaa-0000-0000-0000-000000000004'''
\set ruth   '''aaaaaaaa-0000-0000-0000-000000000005'''

\set as_pg     'reset role; set local request.jwt.claim.sub = '''';'
\set as_admin  'reset role; set local request.jwt.claim.sub = ' :admin ';  set local role authenticated;'
\set as_mentor 'reset role; set local request.jwt.claim.sub = ' :mentor '; set local role authenticated;'
\set as_grace  'reset role; set local request.jwt.claim.sub = ' :grace '; set local role authenticated;'
\set as_daniel 'reset role; set local request.jwt.claim.sub = ' :daniel '; set local role authenticated;'
\set as_ruth   'reset role; set local request.jwt.claim.sub = ' :ruth '; set local role authenticated;'

begin;

-- Start from a clean slate inside this transaction (rolled back at the end, so demo data survives).
delete from public.overrides;
delete from public.extensions;
delete from public.level_reviews;
delete from auth.users;

-- ---------------------------------------------------------------- 0. calculators
do $$ begin
  assert public.daily_band(79.5) = '80-100', 'band rounds to whole number first';
  assert public.daily_band(44.4) = '20-44';
  assert public.daily_band(59.2) = '45-59';
  assert public.daily_band(19.4) = '0-19';
  assert public.weekly_grade(70) = 'Growing' and public.weekly_grade(62) = 'Getting there';
  assert public.weekly_grade(46) = 'Struggling' and public.weekly_grade(39) = 'Not growing';
  assert public.in_local_window('2026-11-16 11:10+00', 'Africa/Lagos', '12:00', 30), '11:10 UTC is 12:10 in Lagos';
  assert not public.in_local_window('2026-11-16 12:10+00', 'Africa/Lagos', '12:00', 30);
end $$;

-- ---------------------------------------------------------------- 1. signup + approval
-- Release time two hours ago in the community time zone, so a day is open right now.
update public.settings set community_tz = 'UTC',
  release_time = (date_trunc('minute', now() at time zone 'UTC') - interval '2 hours')::time;

insert into auth.users (id, email, raw_user_meta_data, email_confirmed_at) values
  (:admin,  'admin@lga.test',  '{"full_name":"Pst Admin"}', now()),
  (:mentor, 'james@lga.test',  '{"full_name":"James"}', now()),
  (:grace,  'grace@lga.test',  '{"full_name":"Grace","phone":"+2348000000001","consents":{"terms_privacy":true,"reminders":true}}', now()),
  (:daniel, 'daniel@lga.test', '{"full_name":"Daniel"}', now()),
  (:ruth,   'ruth@lga.test',   '{"full_name":"Ruth"}', now());

do $$ begin
  assert (select count(*) from public.profiles where status = 'pending') = 5, 'everyone starts pending';
  assert (select count(*) from public.consents where user_id = 'aaaaaaaa-0000-0000-0000-000000000003') = 2;
end $$;

update public.profiles set roles = '{admin}', status = 'active' where id = :admin;
update public.profiles set roles = '{mentor}', status = 'active' where id = :mentor;

:as_admin
select public.approve_member(:grace::uuid,  2, :mentor::uuid, :daniel::uuid);
select public.approve_member(:daniel::uuid, 2, :mentor::uuid);
select public.approve_member(:ruth::uuid,   1, :mentor::uuid);
:as_pg
do $$ begin
  assert (select buddy_id from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000004')
       = 'aaaaaaaa-0000-0000-0000-000000000003', 'buddy pairs are mutual';
end $$;

-- ---------------------------------------------------------------- 2. day opens (sweep)
select public.run_sweep();
do $$ begin
  assert (select count(*) from public.member_days) = 3, 'three members got a day';
  assert (select count(*) from public.daily_tasks) = 16, 'all four levels have tasks today';
end $$;

-- ---------------------------------------------------------------- 2b. voice notes OFF (the default)
:as_daniel
do $$ declare t_oral uuid; begin
  assert public.voice_notes_enabled() = false, 'voice notes are off by default';
  select id into t_oral from public.daily_tasks where is_oral;
  perform public.submit_report(t_oral, 'partial');   -- oral tasks use the normal buttons while voice is off
  begin perform public.submit_voice_report(t_oral, 'aaaaaaaa-0000-0000-0000-000000000004/x.webm', 'audio/webm', 30, 1000);
        raise exception 'EXPECTED FAILURE';
  exception when sqlstate 'P0001' then if sqlerrm = 'EXPECTED FAILURE' then raise; end if; end;
end $$;
:as_pg
update public.settings set voice_notes_enabled = true;   -- switch voice on for the voice checks below

-- ---------------------------------------------------------------- 3. reporting + visibility
:as_grace
do $$
declare t_prayer uuid; t_read uuid; t_oral uuid; t_fast uuid; sc numeric;
begin
  assert (select count(*) from public.daily_tasks where level = 1) = 0, 'a member never sees other levels';
  assert (select count(*) from public.daily_tasks where level = 2) = 4;
  select id into t_prayer from public.daily_tasks where title like 'Morning prayer%';
  select id into t_read   from public.daily_tasks where title like 'Read one chapter%';
  select id into t_oral   from public.daily_tasks where is_oral;
  perform public.submit_report(t_prayer, 'done');
  perform public.submit_report(t_read, 'partial');
  sc := public.live_day_score('aaaaaaaa-0000-0000-0000-000000000003', (select max(day_date) from public.member_days));
  assert sc = 37.5, format('(100+50+0+0)/4 = 37.5, got %s', sc);
  -- oral task cannot be marked by hand, a voice note counts as Done
  begin perform public.submit_report(t_oral, 'done'); raise exception 'EXPECTED FAILURE';
  exception when sqlstate 'P0001' then if sqlerrm = 'EXPECTED FAILURE' then raise; end if; end;
  perform public.submit_voice_report(t_oral, 'aaaaaaaa-0000-0000-0000-000000000003/n1.webm', 'audio/webm', 40, 90000);
  sc := public.live_day_score('aaaaaaaa-0000-0000-0000-000000000003', (select max(day_date) from public.member_days));
  assert sc = 62.5, format('with voice note 62.5, got %s', sc);
  -- someone else's folder is refused
  begin perform public.submit_voice_report(t_oral, 'aaaaaaaa-0000-0000-0000-000000000004/x.webm', 'audio/webm', 40, 1000);
        raise exception 'EXPECTED FAILURE';
  exception when sqlstate '42501' or sqlstate 'P0001' then if sqlerrm = 'EXPECTED FAILURE' then raise; end if; end;
end $$;

:as_daniel
do $$ declare t_prayer uuid; begin
  select id into t_prayer from public.daily_tasks where title like 'Morning prayer%';
  perform public.submit_report(t_prayer, 'not_done');
  -- Daniel (grace's buddy) cannot read Grace's raw reports or alerts rows directly
  assert (select count(*) from public.task_reports where user_id = 'aaaaaaaa-0000-0000-0000-000000000003') = 0;
  assert (select count(*) from public.member_days  where user_id = 'aaaaaaaa-0000-0000-0000-000000000003') = 0;
  -- but the buddy RPC shows Grace's statuses
  assert (public.buddy_overview()->>'name') = 'Grace';
  assert jsonb_array_length(public.buddy_overview()->'tasks') = 4;
end $$;

-- ---------------------------------------------------------------- 4. mentor override
:as_mentor
do $$ declare t_prayer uuid; oid uuid; begin
  select id into t_prayer from public.daily_tasks where title like 'Morning prayer%' and level = 2;
  begin perform public.override_report('aaaaaaaa-0000-0000-0000-000000000004', t_prayer, 'done', '  ');
        raise exception 'EXPECTED FAILURE';
  exception when sqlstate 'P0001' then if sqlerrm = 'EXPECTED FAILURE' then raise; end if; end;
  oid := public.override_report('aaaaaaaa-0000-0000-0000-000000000004', t_prayer, 'done', 'I prayed with him');
  assert (select from_status from public.overrides where id = oid) = 'not_done', 'original value saved';
  assert (select count(*) from public.overrides) = 1, 'mentor sees the audit row';
  assert (select count(*) from public.mentor_dashboard()) = 3;
  -- Ruth is Level 1 and in the same mentor group, so she shows up too
end $$;

:as_daniel
do $$ declare t_prayer uuid; begin
  select id into t_prayer from public.daily_tasks where title like 'Morning prayer%';
  assert (select count(*) from public.overrides) = 1, 'member sees the override (reason shown to them)';
  begin perform public.submit_report(t_prayer, 'not_done'); raise exception 'EXPECTED FAILURE';
  exception when sqlstate 'P0001' then if sqlerrm = 'EXPECTED FAILURE' then raise; end if; end;
end $$;

:as_grace
do $$ begin
  assert (select count(*) from public.overrides) = 0, 'buddies never see override details';
  assert (public.buddy_overview()::text not like '%reason%');
end $$;

-- ---------------------------------------------------------------- 5. deadline: unreported -> Not done, missed day
:as_pg
update public.member_days set deadline_at = now() - interval '1 minute';
select public.run_sweep();
do $$ declare d date := (select max(day_date) from public.member_days); begin
  assert (select count(*) from public.member_days where closed_at is null) = 0, 'all days closed';
  assert (select count(*) from public.task_reports where source = 'auto_deadline') > 0;
  assert (select count(*) from public.task_reports where user_id = 'aaaaaaaa-0000-0000-0000-000000000003') = 4,
         'every task has a final status';
  assert (select score from public.member_days where user_id = 'aaaaaaaa-0000-0000-0000-000000000003') = 62.50;
  assert (select reported_any from public.member_days where user_id = 'aaaaaaaa-0000-0000-0000-000000000005') = false;
  assert exists (select 1 from public.alerts where user_id = 'aaaaaaaa-0000-0000-0000-000000000005' and kind = 'missed_day'),
         'first missed day alerts';
  assert exists (select 1 from public.notifications where user_id = 'aaaaaaaa-0000-0000-0000-000000000002'
                   and template_key = 'missed_day' and channel = 'email'), 'mentor is notified';
  assert (select count(*) from public.alerts where user_id = 'aaaaaaaa-0000-0000-0000-000000000003') = 0;
  -- the sweep is safe to run again
  perform public.run_sweep();
  assert (select count(*) from public.alerts where user_id = 'aaaaaaaa-0000-0000-0000-000000000005') = 1;
end $$;

-- ---------------------------------------------------------------- 6. three missed days in a row -> red alert
insert into public.member_days (user_id, day_date, level, release_at, deadline_at, reported_any, closed_at, score)
select 'aaaaaaaa-0000-0000-0000-000000000005', md.day_date - g, 1, now(), now(), false, now(), 0
from public.member_days md, generate_series(1, 2) g
where md.user_id = 'aaaaaaaa-0000-0000-0000-000000000005';
select public.register_missed_day('aaaaaaaa-0000-0000-0000-000000000005',
  (select max(day_date) from public.member_days));
do $$ begin
  assert public.missed_streak('aaaaaaaa-0000-0000-0000-000000000005') = 3;
  assert exists (select 1 from public.alerts where user_id = 'aaaaaaaa-0000-0000-0000-000000000005' and kind = 'red_alert');
  assert exists (select 1 from public.notifications where user_id = 'aaaaaaaa-0000-0000-0000-000000000001'
                   and template_key = 'red_alert'), 'admin is told about a red alert';
end $$;

-- ---------------------------------------------------------------- 7. extensions (max 3 per date, combined)
:as_mentor
do $$ begin
  assert public.grant_extension('member', null, 'aaaaaaaa-0000-0000-0000-000000000005') = 2;
  assert (select closed_at from public.member_days where user_id = 'aaaaaaaa-0000-0000-0000-000000000005'
            and day_date = (select max(day_date) from public.member_days)) is null, 'closed day re-opened';
  assert (select count(*) from public.task_reports where user_id = 'aaaaaaaa-0000-0000-0000-000000000005') = 0,
         'auto Not done rows removed on re-open';
  assert public.grant_extension('mentees') = 1;
end $$;
:as_admin
do $$ begin
  assert public.grant_extension('everyone') = 0;
  begin perform public.grant_extension('everyone'); raise exception 'EXPECTED FAILURE';
  exception when sqlstate 'P0001' then if sqlerrm = 'EXPECTED FAILURE' then raise; end if; end;
  assert (select count(*) from public.extensions) = 3, 'the 4th extension is refused';
end $$;

-- ---------------------------------------------------------------- 8. level review (2 of 3 months Growing)
:as_pg
insert into public.member_days (user_id, day_date, level, release_at, deadline_at, reported_any, closed_at, score)
select 'aaaaaaaa-0000-0000-0000-000000000003', d, 2, now(), now(), true, now(), 82
from (values (date_trunc('month', current_date)::date - 40), (date_trunc('month', current_date)::date - 70)) v(d);

:as_admin
do $$ declare rid uuid; begin
  rid := public.admin_prepare_level_review(date_trunc('month', current_date)::date);
  assert (select count(*) from public.level_review_items where review_id = rid) = 1, 'only qualifiers are listed';
  assert public.decide_review_items(rid, true) = 1;
  assert (select level from public.profiles where id = 'aaaaaaaa-0000-0000-0000-000000000003') = 3;
  assert (select count(*) from public.level_history where reason = 'review') = 1;
  assert (select status from public.level_reviews where id = rid) = 'completed';
end $$;

-- ---------------------------------------------------------------- 9. permissions are enforced server-side
:as_grace
do $$ begin
  begin perform public.approve_member('aaaaaaaa-0000-0000-0000-000000000005'); raise exception 'EXPECTED FAILURE';
  exception when sqlstate '42501' then null; end;
  begin update public.profiles set level = 4 where id = 'aaaaaaaa-0000-0000-0000-000000000003'; raise exception 'EXPECTED FAILURE';
  exception when sqlstate '42501' then null; end;
  begin perform public.grant_extension('everyone'); raise exception 'EXPECTED FAILURE';
  exception when sqlstate '42501' then null; end;
  begin insert into public.tasks (level, title, start_date) values (1, 'x', current_date); raise exception 'EXPECTED FAILURE';
  exception when sqlstate '42501' then null; end;
  begin perform public.run_sweep(); raise exception 'EXPECTED FAILURE';
  exception when sqlstate '42501' then null; end;
end $$;
:as_mentor
do $$ begin
  begin perform public.approve_member('aaaaaaaa-0000-0000-0000-000000000005'); raise exception 'EXPECTED FAILURE';
  exception when sqlstate '42501' then null; end;
end $$;

\echo 'ALL SCENARIO CHECKS PASSED'
rollback;
