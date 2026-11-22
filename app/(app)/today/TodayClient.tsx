"use client";
import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import VoiceRecorder from "@/components/VoiceRecorder";
import { createClient } from "@/lib/supabase/client";
import { bandFor, formatHours, gradeClass, gradeFor, statusLabel } from "@/lib/scoring";
import type { DailyTask, MemberDay, OverrideInfo, ReportStatus, TaskReport } from "@/lib/types";

interface Props {
  userId: string;
  day: MemberDay;
  tasks: DailyTask[];
  reports: TaskReport[];
  overrides: OverrideInfo[];
  score: number | null;
  weekAvg: number | null;
  history: { day_date: string; score: number | null }[];
  maxSeconds: number;
  maxBytes: number;
  voiceEnabled: boolean;
}

const STATUSES: ReportStatus[] = ["done", "partial", "not_done"];
const THREE_HOURS = 3 * 3600 * 1000;

export default function TodayClient({ userId, day, tasks, reports, overrides, score, weekAvg, history, maxSeconds, maxBytes, voiceEnabled }: Props) {
  const router = useRouter();
  const [now, setNow] = useState(() => Date.now());
  const [pending, setPending] = useState<Record<string, ReportStatus>>({});
  const [error, setError] = useState<string | null>(null);

  const deadline = new Date(day.deadline_at).getTime();
  const msLeft = deadline - now;
  const expired = msLeft <= 0 || day.closed_at !== null;

  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 30_000);
    return () => clearInterval(id);
  }, []);
  // The sweep closes the day within minutes of the deadline; refresh once so final statuses appear.
  useEffect(() => {
    if (msLeft <= 0 && !day.closed_at) {
      const t = setTimeout(() => router.refresh(), 20_000);
      return () => clearTimeout(t);
    }
  }, [msLeft, day.closed_at, router]);
  useEffect(() => setPending({}), [reports]);

  const reportOf = useCallback((id: string) => reports.find((r) => r.daily_task_id === id), [reports]);
  const statusOf = (id: string): ReportStatus | null =>
    pending[id] ?? reportOf(id)?.status ?? (expired ? "not_done" : null);
  const remaining = tasks.filter((t) => !pending[t.id] && !reportOf(t.id)).length;

  async function report(taskId: string, status: ReportStatus) {
    setError(null);
    setPending((p) => ({ ...p, [taskId]: status }));
    const { error } = await createClient().rpc("submit_report", { p_daily_task_id: taskId, p_status: status });
    if (error) {
      setPending((p) => {
        const { [taskId]: _drop, ...rest } = p;
        return rest;
      });
      return setError(error.message);
    }
    router.refresh();
  }

  const grade = gradeFor(weekAvg);

  return (
    <div className="stack">
      <div className="card row between">
        <div>
          <div className="score">{score == null ? "–" : `${Math.round(score)}%`}</div>
          <div className="muted">Today · band {bandFor(score)}%</div>
        </div>
        <div style={{ textAlign: "right" }}>
          {grade && <div className={gradeClass[grade]}>{grade}</div>}
          <div className="muted">Weekly average {weekAvg == null ? "–" : `${Math.round(weekAvg)}%`}</div>
        </div>
      </div>

      <div className="banner" role="status">
        {expired ? "Reporting for today is closed." : `Time left to report: ${formatHours(msLeft)}`}
      </div>
      {!expired && remaining > 0 && msLeft <= THREE_HOURS && (
        <div className="banner error" role="alert">
          {remaining} task{remaining > 1 ? "s" : ""} still unreported. Report before time runs out, or they will count as Not done.
        </div>
      )}
      {error && <div className="banner error" role="alert">{error}</div>}

      {tasks.map((t) => {
        const r = reportOf(t.id);
        const st = statusOf(t.id);
        const ov = r ? overrides.find((o) => o.report_id === r.id) : undefined;
        const locked = expired || r?.source === "mentor_override";
        return (
          <section key={t.id} className="card">
            <div className="row between" style={{ alignItems: "flex-start" }}>
              <h3>{t.title}</h3>
              <span className={`badge ${st ?? ""}`}>{st ? statusLabel[st] : "Not reported"}</span>
            </div>
            {ov && (
              <div className="banner" style={{ marginTop: ".5rem" }}>
                Changed by your mentor from {ov.from_status ? statusLabel[ov.from_status] : "Not reported"} to {statusLabel[ov.to_status]}.
                <div className="muted">Reason: {ov.reason}</div>
              </div>
            )}
            {t.is_oral && voiceEnabled ? (
              r ? (
                <p className="muted" style={{ marginTop: ".5rem" }}>
                  {r.source === "voice_note" ? "Voice note submitted. It will be shared in Reflections." : "Reported."}
                </p>
              ) : expired ? null : (
                <VoiceRecorder
                  taskId={t.id}
                  userId={userId}
                  maxSeconds={maxSeconds}
                  maxBytes={maxBytes}
                  disabled={false}
                  onSubmitted={() => router.refresh()}
                />
              )
            ) : (
              <div className="seg" role="group" aria-label={`Report: ${t.title}`}>
                {STATUSES.map((s) => (
                  <button
                    key={s}
                    className={`btn ${s}`}
                    aria-pressed={st === s}
                    disabled={locked}
                    onClick={() => report(t.id, s)}
                  >
                    {statusLabel[s]}
                  </button>
                ))}
              </div>
            )}
          </section>
        );
      })}

      <h2>Previous days</h2>
      <div className="card muted">
        {history.length === 0
          ? "No earlier days yet."
          : `Daily scores: ${history.map((h) => (h.score == null ? "–" : `${Math.round(h.score)}%`)).join(", ")}`}
      </div>
    </div>
  );
}
