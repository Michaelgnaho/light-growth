-- TEST PROJECT ONLY. Never run this on the project real members will use:
-- it creates accounts with a publicly known password.
-- Paste into the Supabase SQL Editor and run.
-- Creates five approved demo accounts (password: password123) and opens today's tasks:
--   admin@lga.test (admin) · james@lga.test (mentor) · grace@lga.test (L2) · daniel@lga.test (L2, Grace's buddy) · ruth@lga.test (L1)
begin;

create temp table demo(id uuid, email text, name text, roles public.app_role[], lvl int, mentor text, buddy text) on commit drop;
insert into demo values
  ('dddddddd-0000-0000-0000-000000000001','admin@lga.test', 'Pst. Admin','{admin}',1,null,null),
  ('dddddddd-0000-0000-0000-000000000002','james@lga.test', 'James',     '{mentor}',1,null,null),
  ('dddddddd-0000-0000-0000-000000000003','grace@lga.test', 'Grace',     '{member}',2,'james@lga.test','daniel@lga.test'),
  ('dddddddd-0000-0000-0000-000000000004','daniel@lga.test','Daniel',    '{member}',2,'james@lga.test','grace@lga.test'),
  ('dddddddd-0000-0000-0000-000000000005','ruth@lga.test',  'Ruth',      '{member}',1,'james@lga.test',null);

delete from auth.users where email in (select email from demo);

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        confirmation_token, email_change, email_change_token_new, recovery_token)
select '00000000-0000-0000-0000-000000000000', d.id, 'authenticated', 'authenticated', d.email,
       extensions.crypt('password123', extensions.gen_salt('bf')), now(),
       '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', d.name),
       now(), now(), '', '', '', ''
from demo d;

insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
select gen_random_uuid(), d.id, d.id::text, jsonb_build_object('sub', d.id::text, 'email', d.email), 'email', now(), now(), now()
from demo d;

-- The signup trigger created pending profiles. Approve them as the admin would.
update public.profiles p set status = 'active', roles = d.roles, level = d.lvl, level_since = current_date,
       mentor_id = (select m.id from demo m where m.email = d.mentor)
  from demo d where p.id = d.id;
update public.profiles p set buddy_id = (select b.id from demo b where b.email = d.buddy)
  from demo d where p.id = d.id and d.buddy is not null;

-- Open a day right now: release one hour ago in the community time zone.
update public.settings set community_tz = 'Africa/Lagos',
  release_time = (date_trunc('minute', now() at time zone 'Africa/Lagos') - interval '1 hour')::time;
select public.run_sweep();

commit;
