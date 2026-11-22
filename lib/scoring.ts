// Display helpers only. The database is the source of truth for every score and grade
// (see daily_band / weekly_grade in the migrations); these mirror its rounding rules.

export function bandFor(score: number | null | undefined): string {
  if (score == null) return "";
  const r = Math.round(score);
  if (r >= 80) return "80–100";
  if (r >= 60) return "60–79";
  if (r >= 45) return "45–59";
  if (r >= 20) return "20–44";
  return "0–19";
}

export type Grade = "Growing" | "Getting there" | "Struggling" | "Not growing";

export function gradeFor(avg: number | null | undefined): Grade | null {
  if (avg == null) return null;
  const r = Math.round(avg);
  if (r >= 70) return "Growing";
  if (r >= 55) return "Getting there";
  if (r >= 40) return "Struggling";
  return "Not growing";
}

export const gradeClass: Record<Grade, string> = {
  Growing: "grade-growing",
  "Getting there": "grade-getting",
  Struggling: "grade-struggling",
  "Not growing": "grade-not",
};

export const statusLabel = { done: "Done", partial: "Partial", not_done: "Not done" } as const;

/** Next review date on or after `from`, using the configured review months and day. */
export function nextReviewDate(months: number[], day: number, from = new Date()): string {
  const sorted = [...months].sort((a, b) => a - b);
  for (let y = from.getUTCFullYear(); y <= from.getUTCFullYear() + 1; y++) {
    for (const m of sorted) {
      const d = new Date(Date.UTC(y, m - 1, day));
      if (d.getTime() > from.getTime()) return d.toISOString().slice(0, 10);
    }
  }
  return "";
}

export function formatHours(ms: number): string {
  if (ms <= 0) return "Time is up";
  const totalMin = Math.floor(ms / 60000);
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}
