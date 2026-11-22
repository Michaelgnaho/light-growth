export type ReportStatus = "done" | "partial" | "not_done";

export interface Profile {
  id: string;
  full_name: string;
  email: string;
  status: "pending" | "active" | "suspended" | "rejected";
  roles: ("member" | "mentor" | "admin")[];
  level: number;
  reminder_time: string;
  notify_email: boolean;
  notify_whatsapp: boolean;
  time_zone: string;
}

export interface MemberDay {
  user_id: string;
  day_date: string;
  level: number;
  release_at: string;
  deadline_at: string;
  closed_at: string | null;
  score: number | null;
}

export interface DailyTask {
  id: string;
  title: string;
  is_oral: boolean;
  sort_order: number;
}

export interface TaskReport {
  id: string;
  daily_task_id: string;
  status: ReportStatus;
  source: "member" | "voice_note" | "auto_deadline" | "mentor_override";
}

export interface OverrideInfo {
  report_id: string | null;
  from_status: ReportStatus | null;
  to_status: ReportStatus;
  reason: string;
}
