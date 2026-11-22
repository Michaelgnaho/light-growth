"use client";
import { useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";

interface Props {
  taskId: string;
  userId: string;
  maxSeconds: number;
  maxBytes: number;
  disabled: boolean;
  onSubmitted: () => void;
}

type Phase = "idle" | "recording" | "ready" | "uploading";

// iPhone Safari records audio/mp4, Android Chrome records audio/webm. Pick what the browser supports.
const CANDIDATES = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4;codecs=mp4a.40.2", "audio/mp4", "audio/ogg;codecs=opus"];
const EXT: Record<string, string> = {
  "audio/webm": "webm", "audio/mp4": "m4a", "audio/ogg": "ogg", "audio/mpeg": "mp3",
  "audio/aac": "aac", "audio/x-m4a": "m4a", "audio/m4a": "m4a", "audio/wav": "wav", "audio/x-wav": "wav",
};

export default function VoiceRecorder({ taskId, userId, maxSeconds, maxBytes, disabled, onSubmitted }: Props) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [error, setError] = useState<string | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const [clip, setClip] = useState<{ blob: Blob; url: string; seconds: number; mime: string } | null>(null);
  const recorder = useRef<MediaRecorder | null>(null);
  const stream = useRef<MediaStream | null>(null);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);
  const startedAt = useRef(0);

  useEffect(
    () => () => {
      if (timer.current) clearInterval(timer.current);
      stream.current?.getTracks().forEach((t) => t.stop());
    },
    [],
  );
  useEffect(() => () => { if (clip) URL.revokeObjectURL(clip.url); }, [clip]);

  function setReady(blob: Blob, seconds: number, mime: string) {
    if (blob.size > maxBytes) return setError(`That file is too large (max ${Math.floor(maxBytes / 1048576)} MB).`);
    if (seconds > maxSeconds) return setError(`Voice notes can be at most ${Math.floor(maxSeconds / 60)} minutes.`);
    setClip({ blob, url: URL.createObjectURL(blob), seconds, mime });
    setPhase("ready");
  }

  async function start() {
    setError(null);
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
      return setError("Recording is not available in this browser. Choose a recording from your phone instead.");
    }
    try {
      stream.current = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      return setError("The microphone is blocked. Allow it in your browser settings, or choose a recording instead.");
    }
    const mime = CANDIDATES.find((c) => MediaRecorder.isTypeSupported(c));
    const rec = mime ? new MediaRecorder(stream.current, { mimeType: mime }) : new MediaRecorder(stream.current);
    const chunks: Blob[] = [];
    rec.ondataavailable = (e) => e.data.size && chunks.push(e.data);
    rec.onstop = () => {
      stream.current?.getTracks().forEach((t) => t.stop());
      if (timer.current) clearInterval(timer.current);
      const base = (rec.mimeType || mime || "audio/webm").split(";")[0];
      const seconds = Math.max(1, Math.round((Date.now() - startedAt.current) / 1000));
      setReady(new Blob(chunks, { type: base }), seconds, base);
    };
    recorder.current = rec;
    startedAt.current = Date.now();
    setElapsed(0);
    rec.start();
    setPhase("recording");
    timer.current = setInterval(() => {
      const s = Math.floor((Date.now() - startedAt.current) / 1000);
      setElapsed(s);
      if (s >= maxSeconds && rec.state === "recording") rec.stop();
    }, 250);
  }

  function stop() {
    if (recorder.current?.state === "recording") recorder.current.stop();
  }

  function discard() {
    setClip(null);
    setPhase("idle");
    setError(null);
  }

  function pickFile(file: File | undefined) {
    if (!file) return;
    setError(null);
    const base = file.type.split(";")[0];
    if (!base.startsWith("audio/") || !EXT[base]) return setError("Please choose an audio recording (m4a, mp3, webm, wav).");
    const url = URL.createObjectURL(file);
    const probe = new Audio(url);
    probe.onloadedmetadata = () => {
      URL.revokeObjectURL(url);
      if (!Number.isFinite(probe.duration)) return setError("We could not read the length of that file. Try recording here instead.");
      setReady(file, Math.max(1, Math.round(probe.duration)), base);
    };
    probe.onerror = () => { URL.revokeObjectURL(url); setError("We could not open that file."); };
  }

  async function submit() {
    if (!clip) return;
    setPhase("uploading");
    setError(null);
    const supabase = createClient();
    const path = `${userId}/${taskId}-${Date.now()}.${EXT[clip.mime] ?? "webm"}`;
    const up = await supabase.storage.from("voice-notes").upload(path, clip.blob, { contentType: clip.mime });
    if (up.error) {
      setPhase("ready");
      return setError("Upload failed. Check your connection and try again.");
    }
    const { error } = await supabase.rpc("submit_voice_report", {
      p_daily_task_id: taskId,
      p_storage_path: path,
      p_mime_type: clip.mime,
      p_duration_seconds: clip.seconds,
      p_size_bytes: clip.blob.size,
    });
    if (error) {
      setPhase("ready");
      return setError(error.message);
    }
    setClip(null);
    setPhase("idle");
    onSubmitted();
  }

  const mmss = (s: number) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;

  return (
    <div className="recorder stack">
      {phase === "idle" && (
        <>
          <button className="btn btn-primary block" onClick={start} disabled={disabled}>Record voice note</button>
          <label className="field">
            <span>Or choose a recording:</span>
            <input type="file" accept="audio/*" disabled={disabled} onChange={(e) => pickFile(e.target.files?.[0])} />
          </label>
        </>
      )}
      {phase === "recording" && (
        <>
          <div role="status"><span className="rec-dot" />Recording {mmss(elapsed)} / {mmss(maxSeconds)}</div>
          <button className="btn btn-gold block" onClick={stop}>Stop</button>
        </>
      )}
      {(phase === "ready" || phase === "uploading") && clip && (
        <>
          <audio controls src={clip.url} />
          <div className="row">
            <button className="btn" onClick={discard} disabled={phase === "uploading"}>Discard</button>
            <button className="btn btn-primary" style={{ flex: 1 }} onClick={submit} disabled={phase === "uploading"}>
              {phase === "uploading" ? "Submitting…" : "Submit"}
            </button>
          </div>
        </>
      )}
      {error && <div className="banner error" role="alert">{error}</div>}
    </div>
  );
}
