-- OPTIONAL: example tasks copied from the prototype so you can try the app.
-- Run once in the Supabase SQL Editor, then replace them with the Academy's real tasks.
-- Tasks repeat daily from the start date. The 'Oral report' tasks are shown as normal
-- Done / Partial / Not done tasks while voice notes are switched off.
insert into public.tasks (level, title, is_oral, sort_order, start_date) values
  (1, 'Morning prayer (10 min)',               false, 1, current_date),
  (1, 'Read one Psalm',                        false, 2, current_date),
  (1, 'Oral report: share one lesson',         true,  3, current_date),
  (1, 'Encourage someone',                     false, 4, current_date),
  (2, 'Morning prayer (20 min)',               false, 1, current_date),
  (2, 'Read one chapter of Proverbs',          false, 2, current_date),
  (2, 'Oral report: share a reflection',       true,  3, current_date),
  (2, 'Fast until noon',                       false, 4, current_date),
  (3, 'Prayer and journaling (30 min)',        false, 1, current_date),
  (3, 'Read two chapters',                     false, 2, current_date),
  (3, 'Oral report: share a testimony',        true,  3, current_date),
  (3, 'Serve someone in need',                 false, 4, current_date),
  (4, 'Prayer (45 min)',                       false, 1, current_date),
  (4, 'Study a passage in depth',              false, 2, current_date),
  (4, 'Oral report: teach a short lesson',     true,  3, current_date),
  (4, 'Mentor someone',                        false, 4, current_date);
