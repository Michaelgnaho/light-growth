import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { nextReviewDate } from "@/lib/scoring";
import type { DailyTask, MemberDay, OverrideInfo, Profile, TaskReport } from "@/lib/types";
import TodayClient from "./TodayClient";

export const metadata = { title: "Today" };

export default async function TodayPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const [{ data: profile }, { data: settings }] = await Promise.all([
    supabase.from("profiles").select("*").eq("id", user.id).single<Profile>(),
    supabase.from("settings").select("voice_max_seconds, voice_max_bytes, review_months, review_day").single(),
  ]);
  if (!profile || !settings) redirect("/login");

  const firstName = profile.full_name.split(" ")[0];
  const review = nextReviewDate(settings.review_months, settings.review_day);

  const header = (
    <div>
      <h1>Hello, {firstName}</h1>
      <p className="muted">
        Level {profile.level} · next level review {review}
      </p>
    </div>
  );

  // The member's latest released day. RLS only returns rows for this member.
  const { data: day } = await supabase
    .from("member_days")
    .select("*")
    .eq("user_id", user.id)
    .lte("release_at", new Date().toISOString())
    .order("day_date", { ascending: false })
    .limit(1)
    .maybeSingle<MemberDay>();

  if (!day) {
    return (
      <div className="stack">
        {header}
        <div className="card">
          <h2>No tasks yet</h2>
          <p className="muted">Today&apos;s tasks appear here when they are released. Check back soon.</p>
        </div>
      </div>
    );
  }

  const [tasksRes, reportsRes, overridesRes, scoreRes, weekRes, historyRes, voiceRes] = await Promise.all([
    supabase.from("daily_tasks").select("id, title, is_oral, sort_order").eq("day_date", day.day_date).eq("level", day.level).order("sort_order"),
    supabase.from("task_reports").select("id, daily_task_id, status, source").eq("user_id", user.id).eq("day_date", day.day_date),
    supabase
      .from("overrides")
      .select("report_id, from_status, to_status, reason")
      .eq("user_id", user.id)
      .eq("day_date", day.day_date)
      .is("reversed_at", null)
      .order("created_at", { ascending: false }),
    supabase.rpc("live_day_score", { p_user: user.id, p_day: day.day_date }),
    supabase.rpc("week_avg", { p_user: user.id, p_ref: day.day_date }),
    supabase.from("member_days").select("day_date, score").eq("user_id", user.id).lt("day_date", day.day_date).order("day_date", { ascending: false }).limit(7),
    supabase.rpc("voice_notes_enabled"),
  ]);

  return (
    <div className="stack">
      {header}
      <TodayClient
        userId={user.id}
        day={day}
        tasks={(tasksRes.data ?? []) as DailyTask[]}
        reports={(reportsRes.data ?? []) as TaskReport[]}
        overrides={(overridesRes.data ?? []) as OverrideInfo[]}
        score={day.score ?? (scoreRes.data as number | null)}
        weekAvg={weekRes.data as number | null}
        history={(historyRes.data ?? []) as { day_date: string; score: number | null }[]}
        maxSeconds={settings.voice_max_seconds}
        maxBytes={settings.voice_max_bytes}
        voiceEnabled={voiceRes.data === true}
      />
    </div>
  );
}
