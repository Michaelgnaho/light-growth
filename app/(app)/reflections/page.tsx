import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export const metadata = { title: "Reflections" };

interface Note {
  note_id: string;
  member_name: string;
  member_level: number;
  created_at: string;
  storage_path: string;
  duration_seconds: number;
}

export default async function ReflectionsPage() {
  const supabase = await createClient();
  const { data: voiceOn } = await supabase.rpc("voice_notes_enabled");
  if (voiceOn !== true) redirect("/today");
  const { data } = await supabase.rpc("community_reflections", { p_limit: 30 });
  const notes = (data ?? []) as Note[];

  // Voice notes are in a private bucket; storage policies allow active members to create signed links.
  const signed = notes.length
    ? await supabase.storage.from("voice-notes").createSignedUrls(notes.map((n) => n.storage_path), 3600)
    : { data: [] as { path: string | null; signedUrl: string }[] };
  const urlByPath = new Map((signed.data ?? []).map((s) => [s.path, s.signedUrl]));

  return (
    <div className="stack">
      <h1>Reflections</h1>
      <div className="banner">Voice notes are shared with the whole community so people can learn from each other.</div>
      {notes.length === 0 && <div className="card muted">No voice notes yet.</div>}
      {notes.map((n) => {
        const url = urlByPath.get(n.storage_path) ?? undefined;
        const mins = Math.floor(n.duration_seconds / 60);
        const secs = String(n.duration_seconds % 60).padStart(2, "0");
        return (
          <div key={n.note_id} className="card">
            <strong>{n.member_name}</strong> · Level {n.member_level}
            <div className="muted">
              {new Date(n.created_at).toLocaleDateString(undefined, { day: "numeric", month: "short" })} · {mins}:{secs}
            </div>
            {url ? (
              <audio controls preload="none" src={url} style={{ width: "100%", marginTop: ".5rem" }} />
            ) : (
              <p className="muted">This recording is unavailable.</p>
            )}
          </div>
        );
      })}
    </div>
  );
}
