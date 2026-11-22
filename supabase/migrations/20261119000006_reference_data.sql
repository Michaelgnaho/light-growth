-- Starting data every installation needs: levels, message templates and page placeholders.
-- Safe to re-run. Names and descriptions are editable later (table editor or admin screens).

insert into public.levels (level, name, description) values
  (1, 'Foundation',   'Learning to show up. Build a consistent daily rhythm of prayer and Scripture.'),
  (2, 'Discipline',   'Growing strong. Deeper prayer and study, and disciplines such as fasting.'),
  (3, 'Fruitfulness', 'Living it out through service, kindness, testimony and character.'),
  (4, 'Leadership',   'Multiplying. Guide and mentor others and help new believers begin.')
on conflict (level) do nothing;

insert into public.notification_templates (key, channel, subject, body) values
  ('approved',            'email', 'Welcome to Light Growth Academy', 'Hi {{name}}, your account is approved. Open the app to see today''s tasks.'),
  ('reminder',            'email', 'Your Academy tasks: {{remaining}} left', 'You have {{remaining}} task(s) left and about {{hours_left}} hours to report.'),
  ('missed_day',          'email', '{{member_name}} did not report', '{{member_name}} did not report on {{day}}. Please reach out with care.'),
  ('red_alert',           'email', 'Red alert: {{member_name}}', '{{member_name}} has not reported for {{streak}} days in a row (latest: {{day}}).'),
  ('extension_granted',   'email', 'You have extra time', 'You have been given 24 more hours to report for {{day}}.'),
  ('override_made',       'email', 'A report was updated', 'Your mentor changed "{{task}}" to {{new_status}}. Reason: {{reason}}'),
  ('level_review_result', 'email', 'Your level review', 'Congratulations, you have moved up to Level {{new_level}}.')
on conflict do nothing;

-- WhatsApp rows reuse the same wording; each needs a pre-approved template name at the provider.
insert into public.notification_templates (key, channel, subject, body, whatsapp_template)
select key, 'whatsapp', null, body, 'lga_' || key
from public.notification_templates where channel = 'email'
on conflict do nothing;

insert into public.page_content (key, content) values
  ('home',    '{"headline": "Growing in the Word. Walking in the light."}'),
  ('about',   '{}'),
  ('privacy', '{}'),
  ('terms',   '{}'),
  ('contact', '{}')
on conflict (key) do nothing;
