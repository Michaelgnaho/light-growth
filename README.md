# Light Growth Academy

A spiritual growth community app: daily tasks, honest reporting within 24 hours, weekly grades, four levels, buddies and mentors.
Next.js 15 (installable PWA) + Supabase (online). **Voice recording is switched off for now** (see the end of this file).

## Set up (about 20 minutes)

You need Node 20+ and a free account at supabase.com. No Docker.

**1. Install**
```bash
npm install
```

**2. Create the online database**
1. At supabase.com click **New project**. Pick a name, a region (London is a sensible choice), and a database password. Save the password.
2. When it is ready, open **Project Settings → API** and copy the **Project URL** and the **anon / publishable key**.

**3. Connect the app**
1. Copy `.env.example` to a new file named `.env.local`.
2. Paste the two values into it.

**4. Send the tables to Supabase**
```bash
npm run db:login     # opens the browser to log in
npm run db:link      # choose your project from the list
npm run db:push      # asks for the database password; creates everything
```

**5. Allow sign-in emails** (Supabase dashboard → Authentication)
- **Providers → Email:** make sure **Confirm email** is on.
- **URL Configuration:** set **Site URL** to `http://localhost:3000` for now, and add `http://localhost:3000/**` to **Redirect URLs**. When you deploy, add your real address too.
- **Emails → Templates:** paste `supabase/templates/confirmation.html` into **Confirm signup** and `supabase/templates/recovery.html` into **Reset password**.

**6. Check and run**
```bash
npm run check        # confirms the keys work and the database is ready
npm run dev          # http://localhost:3000
```

## First admin, tasks and members (SQL Editor, until the admin screens exist)

In Supabase open **SQL Editor → New query** and run these as needed.

Make yourself admin (register and verify your email in the app first):
```sql
update public.profiles set roles = '{admin,member}', status = 'active' where email = 'you@example.com';
```

Set the release time and time zone:
```sql
update public.settings set community_tz = 'Africa/Lagos', release_time = '06:00';
```

Add tasks (repeat for levels 2 to 4). Tasks repeat daily from the start date. Use `recurrence = 'biweekly'` for every two weeks:
```sql
insert into public.tasks (level, title, sort_order, start_date) values
  (1, 'Morning prayer (10 min)', 1, current_date),
  (1, 'Read one Psalm', 2, current_date);
```
To try the app first, run the example tasks in `supabase/sample-tasks.sql`, then delete them: `delete from public.tasks;`

Approve a member, set level and mentor (make a mentor with `roles = '{mentor}'`):
```sql
update public.profiles
set status = 'active', level = 1, level_since = current_date,
    mentor_id = (select id from public.profiles where email = 'mentor@example.com')
where email = 'new.member@example.com';
```
Pair two buddies:
```sql
update public.profiles
set buddy_id = case email when 'a@example.com' then (select id from public.profiles where email = 'b@example.com')
                          when 'b@example.com' then (select id from public.profiles where email = 'a@example.com') end
where email in ('a@example.com', 'b@example.com');
```

Optional, **test project only**: `supabase/seed-demo.sql` creates demo accounts (password `password123`). Never run it on the project real members use.

## Put it online

1. Push the code to a private GitHub repository (`.env.local` is ignored, so keys stay private).
2. On vercel.com choose **Add New → Project**, import the repository, and add the same two environment variables.
3. Add your Vercel (or custom domain) address to Supabase **Authentication → URL Configuration** (Site URL and Redirect URLs).
4. For real members, set up your own email sender in Supabase (**Authentication → Emails → SMTP Settings**). The built-in one allows very few emails.

## Commands

| Command | What it does |
|---|---|
| `npm run dev` / `build` / `start` | Next.js |
| `npm run typecheck` | TypeScript check |
| `npm run check` | Checks `.env.local` and that Supabase is reachable and set up |
| `npm run db:login` / `db:link` / `db:push` | Log in to Supabase, choose your project, send the database changes |

## What is in the project

| Path | What |
|---|---|
| `app/`, `components/`, `lib/`, `middleware.ts` | Web app: register, log in, reset password, Today, My buddy, Reminders (Reflections returns when voice is on) |
| `supabase/migrations/` | Schema, all business rules, permissions, storage, the scheduled sweep, voice switch, starting data |
| `supabase/templates/` | Email templates for verification and password reset |
| `supabase/sample-tasks.sql`, `seed-demo.sql` | Optional example tasks; optional demo accounts (test project only) |
| `supabase/tests/scenario.sql` | Optional rules test (needs `psql` and a scratch database) |
| `brand/` | Logo pack: svg, png, pdf, favicon |
| `docs/` | Functional specification and invitation |

## Voice notes: off for now

While off, oral tasks are reported with the normal Done / Partial / Not done buttons, and the Reflections tab and the voice consent box are hidden. Nothing is lost: the recording code and storage are still there.
To switch voice on later, run once in the SQL Editor:
```sql
update public.settings set voice_notes_enabled = true;
```
Before then, test recording on a real iPhone and a real Android phone.

## Defaults to confirm with the client

Release time and time zone (06:00 Africa/Lagos for now) · weeks run Monday to Sunday · grades and bands round to a whole number first · "Growing in all 3 months or at least 2 of 3" is stored as at least 2 of the previous 3 calendar months · books are members-only by default · admins and mentors join the daily tasks only if they also have the `member` role.

## Not built yet

Mentor area, Admin area, My Progress, public About and Resources pages, legal pages, and the sender for the queued email and WhatsApp messages. The rules for all of these already exist as database functions.
