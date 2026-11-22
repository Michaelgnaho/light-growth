-- Light Growth Academy: schema (enums + tables)
-- All business logic lives in 20261115000002_functions.sql.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- enums
create type public.app_role         as enum ('member', 'mentor', 'admin');
create type public.account_status   as enum ('pending', 'active', 'suspended', 'rejected');
create type public.report_status    as enum ('done', 'partial', 'not_done');
create type public.report_source    as enum ('member', 'voice_note', 'auto_deadline', 'mentor_override');
create type public.task_recurrence  as enum ('daily', 'biweekly');
create type public.alert_kind       as enum ('missed_day', 'red_alert');
create type public.access_level     as enum ('public', 'members');
create type public.notify_channel   as enum ('email', 'whatsapp', 'in_app');
create type public.notify_status    as enum ('queued', 'sending', 'sent', 'delivered', 'failed');
create type public.extension_scope  as enum ('member', 'mentees', 'everyone');
create type public.review_decision  as enum ('pending', 'approved', 'rejected');

-- ---------------------------------------------------------------- settings (single row)
create table public.settings (
  id                      boolean primary key default true check (id),
  community_tz            text    not null default 'Africa/Lagos',          -- TBC with client
  release_time            time    not null default '06:00',                 -- TBC with client
  partial_value           int     not null default 50 check (partial_value between 0 and 100),
  extension_limit         int     not null default 3  check (extension_limit >= 0),
  voice_max_seconds       int     not null default 180,
  voice_max_bytes         int     not null default 10485760,
  approval_mode           text    not null default 'manual' check (approval_mode in ('manual', 'auto')),
  growing_threshold       int     not null default 70,
  review_months           int[]   not null default '{1,4,7,10}',
  review_day              int     not null default 1 check (review_day between 1 and 28),
  default_second_reminder time    not null default '21:00',
  updated_at              timestamptz not null default now()
);
insert into public.settings default values;

-- ---------------------------------------------------------------- levels
create table public.levels (
  level       int primary key check (level between 1 and 4),
  name        text not null,
  description text not null default ''
);

-- ---------------------------------------------------------------- profiles
create table public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  full_name        text not null,
  email            text not null,
  phone            text,
  country          text,
  time_zone        text not null default 'Africa/Lagos',
  referral_source  text,
  roles            public.app_role[] not null default '{member}',
  status           public.account_status not null default 'pending',
  level            int  not null default 1 references public.levels (level),
  level_since      date,
  mentor_id        uuid references public.profiles (id) on delete set null,
  buddy_id         uuid unique references public.profiles (id) on delete set null,
  mentor_sees_all  boolean not null default false,   -- mentor's "also show other mentors' members" switch
  reminder_time    time not null default '12:00',
  notify_email     boolean not null default true,
  notify_whatsapp  boolean not null default true,
  whatsapp_verified boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (buddy_id  is distinct from id),
  check (mentor_id is distinct from id)
);
create index profiles_mentor_idx on public.profiles (mentor_id);
create index profiles_status_idx on public.profiles (status);

-- Append-only consent log (withdrawal = new row with granted=false)
create table public.consents (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references public.profiles (id) on delete cascade,
  consent_type   text not null check (consent_type in ('terms_privacy', 'data_sharing', 'reminders', 'voice_sharing')),
  policy_version text not null,
  granted        boolean not null,
  created_at     timestamptz not null default now()
);
create index consents_user_idx on public.consents (user_id, consent_type, created_at desc);

-- ---------------------------------------------------------------- tasks
-- A task is a template: it applies to every date in [start_date, end_date]
-- (daily) or every 14th day from start_date (biweekly). One-off = start=end.
create table public.tasks (
  id          uuid primary key default gen_random_uuid(),
  level       int  not null references public.levels (level),
  title       text not null,
  is_oral     boolean not null default false,
  recurrence  public.task_recurrence not null default 'daily',
  start_date  date not null,
  end_date    date,
  sort_order  int  not null default 0,
  archived    boolean not null default false,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);
create index tasks_level_idx on public.tasks (level) where not archived;

-- Snapshot of what was actually assigned on a date (permanent record).
create table public.daily_tasks (
  id         uuid primary key default gen_random_uuid(),
  task_id    uuid references public.tasks (id) on delete set null,
  level      int  not null references public.levels (level),
  day_date   date not null,
  title      text not null,
  is_oral    boolean not null default false,
  sort_order int  not null default 0,
  unique (task_id, day_date)
);
create index daily_tasks_day_idx on public.daily_tasks (day_date, level);

-- One row per member per assigned day. Holds release, deadline and final score.
create table public.member_days (
  user_id         uuid not null references public.profiles (id) on delete cascade,
  day_date        date not null,
  level           int  not null references public.levels (level),
  release_at      timestamptz not null,
  deadline_at     timestamptz not null,
  extension_hours int  not null default 0,
  reported_any    boolean not null default false,
  closed_at       timestamptz,
  score           numeric(5, 2),
  primary key (user_id, day_date)
);
create index member_days_open_idx on public.member_days (deadline_at) where closed_at is null;
create index member_days_day_idx  on public.member_days (day_date);

create table public.voice_notes (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null references public.profiles (id) on delete cascade,
  day_date         date not null,
  storage_path     text not null unique,
  mime_type        text not null,
  duration_seconds int  not null check (duration_seconds > 0),
  size_bytes       int  not null check (size_bytes > 0),
  hidden           boolean not null default false,
  created_at       timestamptz not null default now()
);
create index voice_notes_feed_idx on public.voice_notes (created_at desc) where not hidden;

create table public.task_reports (
  id            uuid primary key default gen_random_uuid(),
  daily_task_id uuid not null references public.daily_tasks (id) on delete cascade,
  user_id       uuid not null,
  day_date      date not null,
  status        public.report_status not null,
  source        public.report_source not null default 'member',
  voice_note_id uuid references public.voice_notes (id) on delete set null,
  reported_at   timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (daily_task_id, user_id),
  foreign key (user_id, day_date) references public.member_days (user_id, day_date) on delete cascade
);
create index task_reports_user_day_idx on public.task_reports (user_id, day_date);

-- Audit trail of mentor overrides. report_id survives report deletion as null.
create table public.overrides (
  id          uuid primary key default gen_random_uuid(),
  report_id   uuid references public.task_reports (id) on delete set null,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  day_date    date not null,
  mentor_id   uuid not null references public.profiles (id),
  from_status public.report_status,          -- null = nothing had been reported
  from_source public.report_source,
  to_status   public.report_status not null,
  reason      text not null check (length(btrim(reason)) >= 3),
  created_at  timestamptz not null default now(),
  reversed_at timestamptz,
  reversed_by uuid references public.profiles (id)
);
create index overrides_user_idx   on public.overrides (user_id, day_date);
create index overrides_report_idx on public.overrides (report_id);

create table public.extensions (
  id          bigint generated always as identity primary key,
  day_date    date not null,
  scope       public.extension_scope not null,
  target_user uuid references public.profiles (id) on delete cascade,
  granted_by  uuid not null references public.profiles (id),
  note        text,
  created_at  timestamptz not null default now(),
  check ((scope = 'member') = (target_user is not null))
);
create index extensions_day_idx on public.extensions (day_date);

create table public.alerts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  kind       public.alert_kind not null,
  day_date   date not null,
  streak     int  not null,
  created_at timestamptz not null default now(),
  unique (user_id, kind, day_date)
);

-- ---------------------------------------------------------------- notifications (outbox)
create table public.notification_templates (
  key               text not null,
  channel           public.notify_channel not null,
  subject           text,
  body              text not null,
  whatsapp_template text,                     -- name of the approved WhatsApp template
  primary key (key, channel)
);

create table public.notifications (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references public.profiles (id) on delete cascade,
  channel             public.notify_channel not null,
  template_key        text not null,
  payload             jsonb not null default '{}',
  status              public.notify_status not null default 'queued',
  attempts            int  not null default 0,
  next_attempt_at     timestamptz not null default now(),
  claimed_at          timestamptz,
  provider_message_id text,
  error               text,
  dedupe_key          text,
  created_at          timestamptz not null default now(),
  sent_at             timestamptz,
  unique (user_id, dedupe_key, channel)
);
create index notifications_queue_idx on public.notifications (next_attempt_at) where status = 'queued';
create index notifications_user_idx  on public.notifications (user_id, created_at desc);

-- ---------------------------------------------------------------- level reviews
create table public.level_reviews (
  id           uuid primary key default gen_random_uuid(),
  review_date  date not null unique,
  status       text not null default 'draft' check (status in ('draft', 'completed')),
  prepared_at  timestamptz not null default now(),
  completed_at timestamptz
);

create table public.level_review_items (
  id             uuid primary key default gen_random_uuid(),
  review_id      uuid not null references public.level_reviews (id) on delete cascade,
  user_id        uuid not null references public.profiles (id) on delete cascade,
  from_level     int  not null,
  to_level       int  not null,
  growing_months int  not null,
  month_averages jsonb not null default '{}',
  decision       public.review_decision not null default 'pending',
  decided_by     uuid references public.profiles (id),
  decided_at     timestamptz,
  unique (review_id, user_id)
);

create table public.level_history (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  from_level int not null,
  to_level   int not null,
  reason     text not null,                      -- 'review' | 'reset' | 'manual'
  review_id  uuid references public.level_reviews (id) on delete set null,
  changed_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- content
create table public.books (
  id             uuid primary key default gen_random_uuid(),
  title          text not null,
  description    text not null default '',
  category       text,
  cover_path     text,                           -- bucket: resource-covers (public)
  file_path      text not null,                  -- bucket: resource-files (private)
  access         public.access_level not null default 'members',   -- default TBC with client
  visible        boolean not null default true,
  sort_order     int not null default 0,
  download_count int not null default 0,
  created_at     timestamptz not null default now()
);

create table public.sermons (
  id            uuid primary key default gen_random_uuid(),
  title         text not null,
  sermon_date   date,
  speaker       text,
  description   text not null default '',
  thumbnail_url text,
  url           text not null,
  series        text,
  visible       boolean not null default true,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now()
);

create table public.page_content (
  key         text primary key,                  -- 'home', 'about', 'privacy', 'terms', 'contact'
  content     jsonb not null default '{}',
  updated_by  uuid references public.profiles (id) on delete set null,
  updated_at  timestamptz not null default now()
);

create table public.audit_log (
  id         bigint generated always as identity primary key,
  actor      uuid references public.profiles (id) on delete set null,
  action     text not null,
  entity     text not null,
  entity_id  text,
  details    jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index audit_log_created_idx on public.audit_log (created_at desc);
