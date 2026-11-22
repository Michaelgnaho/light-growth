"use client";
import { useState } from "react";
import SignOutButton from "@/components/SignOutButton";
import { createClient } from "@/lib/supabase/client";
import type { Profile } from "@/lib/types";

const TIMES = Array.from({ length: 48 }, (_, i) => `${String(Math.floor(i / 2)).padStart(2, "0")}:${i % 2 ? "30" : "00"}`);

// Same rule as the database: 9:00 pm, or 7:00 am if the chosen time is between 6:00 pm and 4:59 am.
export function secondReminder(time: string): string {
  const [h] = time.split(":").map(Number);
  return h >= 18 || h < 5 ? "7:00 am" : "9:00 pm";
}

export default function RemindersForm({ profile }: { profile: Profile }) {
  const [time, setTime] = useState(profile.reminder_time.slice(0, 5));
  const [email, setEmail] = useState(profile.notify_email);
  const [whatsapp, setWhatsapp] = useState(profile.notify_whatsapp);
  const [msg, setMsg] = useState<string | null>(null);

  async function save() {
    setMsg(null);
    const { error } = await createClient()
      .from("profiles")
      .update({ reminder_time: time, notify_email: email, notify_whatsapp: whatsapp })
      .eq("id", profile.id);
    setMsg(error ? error.message : "Saved.");
  }

  return (
    <div className="stack">
      <h1>Reminders</h1>
      <div className="card stack">
        <label className="field">
          <span>Your reminder time ({profile.time_zone})</span>
          <select value={time} onChange={(e) => setTime(e.target.value)}>
            {TIMES.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </label>
        <p>Your second reminder: <strong>{secondReminder(time)}</strong>, every day.</p>
        <label className="check"><input type="checkbox" checked={email} onChange={(e) => setEmail(e.target.checked)} /> Email</label>
        <label className="check"><input type="checkbox" checked={whatsapp} onChange={(e) => setWhatsapp(e.target.checked)} /> WhatsApp</label>
        <button className="btn btn-primary" onClick={save}>Save</button>
        {msg && <div className="banner" role="status">{msg}</div>}
      </div>
      <SignOutButton />
    </div>
  );
}
