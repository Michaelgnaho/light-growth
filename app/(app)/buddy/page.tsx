import { createClient } from "@/lib/supabase/server";
import { gradeClass, statusLabel, type Grade } from "@/lib/scoring";
import type { ReportStatus } from "@/lib/types";

export const metadata = { title: "My buddy" };

interface BuddyOverview {
  name: string;
  level: number;
  today_score: number | null;
  week_avg: number | null;
  week_grade: Grade | null;
  tasks: { title: string; is_oral: boolean; status: ReportStatus | null }[];
}

export default async function BuddyPage() {
  const supabase = await createClient();
  const { data } = await supabase.rpc("buddy_overview");
  const b = data as BuddyOverview | null;

  if (!b) {
    return (
      <div className="stack">
        <h1>My buddy</h1>
        <div className="card muted">You have not been paired with a buddy yet. An admin will do this for you.</div>
      </div>
    );
  }
  return (
    <div className="stack">
      <h1>My buddy</h1>
      <div className="card">
        <strong>{b.name}</strong> · Level {b.level}
        <div className="muted">
          Weekly {b.week_avg == null ? "–" : `${Math.round(b.week_avg)}%`}
          {b.week_grade && <> · <span className={gradeClass[b.week_grade]}>{b.week_grade}</span></>}
        </div>
      </div>
      <h2>Today&apos;s tasks</h2>
      {b.tasks.length === 0 && <div className="card muted">No tasks released yet.</div>}
      {b.tasks.map((t) => (
        <div key={t.title} className="card row between">
          <span>{t.title}</span>
          <span className={`badge ${t.status ?? ""}`}>{t.status ? statusLabel[t.status] : "Not reported"}</span>
        </div>
      ))}
    </div>
  );
}
