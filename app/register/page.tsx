"use client";
import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { POLICY_VERSION } from "@/lib/consts";

const CONSENTS = [
  { key: "terms_privacy", label: "I agree to the Terms and Privacy Policy." },
  { key: "data_sharing", label: "I consent to my spiritual practice data being stored and seen by my buddy, my mentor and the admins." },
  { key: "reminders", label: "I agree to receive reminders and alerts by email and WhatsApp." },
  { key: "voice_sharing", label: "I understand my voice notes will be shared with the community." },
] as const;

export default function RegisterPage() {
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);
  const [voiceOn, setVoiceOn] = useState(false);
  useEffect(() => {
    createClient().rpc("voice_notes_enabled").then(({ data }) => setVoiceOn(data === true));
  }, []);
  const consentList = CONSENTS.filter((c) => c.key !== "voice_sharing" || voiceOn);
  const defaultTz = useMemo(() => Intl.DateTimeFormat().resolvedOptions().timeZone || "Africa/Lagos", []);
  const zones = useMemo(() => {
    const all = Intl.supportedValuesOf("timeZone");
    return all.includes(defaultTz) ? all : [defaultTz, ...all];
  }, [defaultTz]);

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    const f = new FormData(e.currentTarget);
    const password = String(f.get("password"));
    if (password.length < 8) return setError("Use a password of at least 8 characters.");
    if (password !== String(f.get("confirm"))) return setError("The two passwords do not match.");
    const phone = String(f.get("phone")).replace(/\s+/g, "");
    if (!/^\+\d{7,15}$/.test(phone)) return setError("Enter your WhatsApp number with the country code, e.g. +2348012345678.");
    const consents: Record<string, boolean> = {};
    for (const c of consentList) consents[c.key] = f.get(c.key) === "on";
    if (Object.values(consents).some((v) => !v)) return setError("Please tick all the consent boxes to join.");

    setBusy(true);
    const supabase = createClient();
    const { error } = await supabase.auth.signUp({
      email: String(f.get("email")).trim(),
      password,
      options: {
        emailRedirectTo: `${window.location.origin}/auth/confirm?next=/today`,
        data: {
          full_name: String(f.get("full_name")).trim(),
          phone,
          country: String(f.get("country")).trim(),
          time_zone: String(f.get("time_zone")),
          referral_source: String(f.get("referral_source")).trim(),
          consents,
          policy_version: POLICY_VERSION,
        },
      },
    });
    setBusy(false);
    if (error) return setError(error.message);
    setSent(true);
  }

  if (sent) {
    return (
      <main className="page narrow stack">
        <h1>Check your email</h1>
        <p>We sent you a link to verify your address. After that, an admin will approve your account and you will get a welcome message.</p>
        <Link href="/login">Back to log in</Link>
      </main>
    );
  }

  return (
    <main className="page narrow stack">
      <h1>Join the Academy</h1>
      <form className="card stack" onSubmit={onSubmit}>
        <label className="field"><span>Full name</span><input name="full_name" type="text" autoComplete="name" required /></label>
        <label className="field"><span>Email</span><input name="email" type="email" autoComplete="email" required /></label>
        <label className="field"><span>WhatsApp number (with country code)</span><input name="phone" type="tel" autoComplete="tel" placeholder="+234…" required /></label>
        <label className="field"><span>Password</span><input name="password" type="password" autoComplete="new-password" minLength={8} required /></label>
        <label className="field"><span>Confirm password</span><input name="confirm" type="password" autoComplete="new-password" required /></label>
        <label className="field"><span>Country</span><input name="country" type="text" autoComplete="country-name" required /></label>
        <label className="field">
          <span>Time zone</span>
          <select name="time_zone" defaultValue={defaultTz}>
            {zones.map((z) => <option key={z} value={z}>{z}</option>)}
          </select>
        </label>
        <label className="field"><span>Church or who invited you (optional)</span><input name="referral_source" type="text" /></label>
        {consentList.map((c) => (
          <label key={c.key} className="check"><input type="checkbox" name={c.key} /> <span>{c.label}</span></label>
        ))}
        {error && <div className="banner error" role="alert">{error}</div>}
        <button className="btn btn-primary block" disabled={busy}>{busy ? "Creating account…" : "Register"}</button>
      </form>
      <p className="muted">Already a member? <Link href="/login">Log in</Link></p>
    </main>
  );
}
