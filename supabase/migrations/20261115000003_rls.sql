-- Light Growth Academy: Row Level Security (spec section 10 + 12).
-- Pattern: tables are read through policies; every WRITE that carries a business rule goes
-- through a SECURITY DEFINER function (0002), so the tables below have no member write policies.
-- Data that must be hidden from some roles (override details, buddy view) is exposed only via RPCs.

alter table public.settings               enable row level security;
alter table public.levels                 enable row level security;
alter table public.profiles               enable row level security;
alter table public.consents               enable row level security;
alter table public.tasks                  enable row level security;
alter table public.daily_tasks            enable row level security;
alter table public.member_days            enable row level security;
alter table public.voice_notes            enable row level security;
alter table public.task_reports           enable row level security;
alter table public.overrides              enable row level security;
alter table public.extensions             enable row level security;
alter table public.alerts                 enable row level security;
alter table public.notification_templates enable row level security;
alter table public.notifications          enable row level security;
alter table public.level_reviews          enable row level security;
alter table public.level_review_items     enable row level security;
alter table public.level_history          enable row level security;
alter table public.books                  enable row level security;
alter table public.sermons                enable row level security;
alter table public.page_content           enable row level security;
alter table public.audit_log              enable row level security;

-- ---------------------------------------------------------------- public / reference data
create policy levels_read   on public.levels for select to anon, authenticated using (true);
create policy levels_admin  on public.levels for all    to authenticated using (public.is_admin()) with check (public.is_admin());

create policy settings_read  on public.settings for select to authenticated using (true);
create policy settings_admin on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy page_content_read  on public.page_content for select to anon, authenticated using (true);
create policy page_content_admin on public.page_content for all    to authenticated using (public.is_admin()) with check (public.is_admin());

-- Cards are visible to everyone; the actual file is gated by record_download().
create policy books_read   on public.books   for select to anon, authenticated using (visible or public.is_admin());
create policy books_admin  on public.books   for all    to authenticated using (public.is_admin()) with check (public.is_admin());
create policy sermons_read  on public.sermons for select to anon, authenticated using (visible or public.is_admin());
create policy sermons_admin on public.sermons for all    to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------- profiles
create policy profiles_self_read   on public.profiles for select to authenticated using (id = auth.uid());
create policy profiles_staff_read  on public.profiles for select to authenticated
  using (public.is_admin() or public.is_mentor_of(id));
create policy profiles_self_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());      -- protected columns: trigger in 0002
create policy profiles_admin_update on public.profiles for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy consents_read   on public.consents for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy consents_insert on public.consents for insert to authenticated
  with check (user_id = auth.uid());                         -- withdrawing = inserting granted=false

-- ---------------------------------------------------------------- tasks and daily records
create policy tasks_admin on public.tasks for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy daily_tasks_read on public.daily_tasks for select to authenticated using (
  public.is_admin() or public.is_mentor()
  or exists (select 1 from public.member_days md
              where md.user_id = auth.uid() and md.day_date = daily_tasks.day_date
                and md.level = daily_tasks.level and md.release_at <= now()));

create policy member_days_read on public.member_days for select to authenticated using (
  user_id = auth.uid() or public.is_admin() or public.is_mentor_of(user_id));

create policy task_reports_read on public.task_reports for select to authenticated using (
  user_id = auth.uid() or public.is_admin() or public.is_mentor_of(user_id));

-- Override details: the member (own), the mentors involved and admins. Never buddies.
create policy overrides_read on public.overrides for select to authenticated using (
  user_id = auth.uid() or mentor_id = auth.uid() or public.is_admin() or public.is_mentor_of(user_id));

create policy voice_notes_read on public.voice_notes for select to authenticated using (
  user_id = auth.uid() or public.is_admin() or (not hidden and public.is_active_user()));
create policy voice_notes_admin_update on public.voice_notes for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy voice_notes_admin_delete on public.voice_notes for delete to authenticated
  using (public.is_admin());

create policy extensions_read on public.extensions for select to authenticated using (
  granted_by = auth.uid() or public.is_admin());

create policy alerts_read on public.alerts for select to authenticated using (
  user_id = auth.uid() or public.is_buddy_of(user_id) or public.is_mentor_of(user_id) or public.is_admin());

-- ---------------------------------------------------------------- notifications, reviews, audit
create policy templates_admin on public.notification_templates for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy notifications_read on public.notifications for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

create policy level_reviews_admin on public.level_reviews      for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy level_items_admin   on public.level_review_items for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy level_history_read  on public.level_history for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

create policy audit_admin_read on public.audit_log for select to authenticated using (public.is_admin());

-- ---------------------------------------------------------------- function privileges
-- Postgres grants EXECUTE to PUBLIC by default. Lock internal jobs down, then open the RPCs.
revoke execute on function
  public.materialize_daily_tasks(date), public.open_day(date), public.close_expired_days(),
  public.register_missed_day(uuid, date), public.enqueue_notification(uuid, text, jsonb, text),
  public.enqueue_due_reminders(), public.run_sweep(), public.prepare_due_level_review(),
  public.build_level_review(date), public.recompute_member_day(uuid, date),
  public.missed_streak(uuid, date), public.log_audit(text, text, text, jsonb),
  public.claim_notifications(int)
from public, anon, authenticated;

revoke execute on function
  public.submit_report(uuid, public.report_status),
  public.submit_voice_report(uuid, text, text, int, int),
  public.buddy_overview(), public.community_reflections(int, timestamptz),
  public.mentor_dashboard(),
  public.override_report(uuid, uuid, public.report_status, text),
  public.extension_usage(date),
  public.grant_extension(public.extension_scope, date, uuid, text),
  public.set_buddy(uuid, uuid), public.clear_buddy(uuid),
  public.approve_member(uuid, int, uuid, uuid), public.reject_member(uuid),
  public.reverse_override(uuid), public.admin_resync_day(date),
  public.admin_prepare_level_review(date), public.decide_review_items(uuid, boolean, uuid[]),
  public.reset_levels(uuid, int), public.admin_overview()
from public, anon;

grant execute on function
  public.submit_report(uuid, public.report_status),
  public.submit_voice_report(uuid, text, text, int, int),
  public.buddy_overview(), public.community_reflections(int, timestamptz),
  public.mentor_dashboard(),
  public.override_report(uuid, uuid, public.report_status, text),
  public.extension_usage(date),
  public.grant_extension(public.extension_scope, date, uuid, text),
  public.set_buddy(uuid, uuid), public.clear_buddy(uuid),
  public.approve_member(uuid, int, uuid, uuid), public.reject_member(uuid),
  public.reverse_override(uuid), public.admin_resync_day(date),
  public.admin_prepare_level_review(date), public.decide_review_items(uuid, boolean, uuid[]),
  public.reset_levels(uuid, int), public.admin_overview()
to authenticated;

-- Download gate is callable by visitors (public books) and members.
grant execute on function public.record_download(uuid) to anon, authenticated;

-- ---------------------------------------------------------------- storage
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('voice-notes',     'voice-notes',     false, 10485760,
     array['audio/webm', 'audio/mp4', 'audio/mpeg', 'audio/ogg', 'audio/aac', 'audio/x-m4a', 'audio/m4a',
           'audio/wav', 'audio/x-wav']),
  ('resource-files',  'resource-files',  false, 52428800, array['application/pdf']),
  ('resource-covers', 'resource-covers', true,  5242880,  array['image/jpeg', 'image/png', 'image/webp']),
  ('site-images',     'site-images',     true,  5242880,  array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- Members upload only into their own folder: voice-notes/<user id>/<file>
create policy voice_upload on storage.objects for insert to authenticated with check (
  bucket_id = 'voice-notes' and (storage.foldername(name))[1] = auth.uid()::text and public.is_active_user());

-- Playback: own files, admins, or any active member for notes that are not hidden.
create policy voice_read on storage.objects for select to authenticated using (
  bucket_id = 'voice-notes' and (
    (storage.foldername(name))[1] = auth.uid()::text
    or public.is_admin()
    or (public.is_active_user() and exists (
          select 1 from public.voice_notes v where v.storage_path = name and not v.hidden))));

create policy voice_admin_delete on storage.objects for delete to authenticated
  using (bucket_id = 'voice-notes' and public.is_admin());

-- Admin manages books, covers and site images (reads of public buckets need no policy).
create policy content_admin_all on storage.objects for all to authenticated
  using (bucket_id in ('resource-files', 'resource-covers', 'site-images') and public.is_admin())
  with check (bucket_id in ('resource-files', 'resource-covers', 'site-images') and public.is_admin());
