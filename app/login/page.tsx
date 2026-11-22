"use client";
import Link from "next/link";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function LoginPage() {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    setError(null);
    setBusy(true);
    const form = new FormData(e.currentTarget);
    const supabase = createClient();
    const { error } = await supabase.auth.signInWithPassword({
      email: String(form.get("email")).trim(),
      password: String(form.get("password")),
    });
    setBusy(false);
    if (error) {
      setError(error.message.includes("Email not confirmed") ? "Please verify your email first. Check your inbox." : error.message);
      return;
    }
    const next = new URLSearchParams(window.location.search).get("next");
    router.replace(next && next.startsWith("/") && !next.startsWith("//") ? next : "/today");
    router.refresh();
  }

  return (
    <main className="page narrow stack">
      <h1>Log in</h1>
      <form className="card stack" onSubmit={onSubmit}>
        <label className="field">
          <span>Email</span>
          <input name="email" type="email" autoComplete="email" required />
        </label>
        <label className="field">
          <span>Password</span>
          <input name="password" type="password" autoComplete="current-password" required />
        </label>
        {error && <div className="banner error" role="alert">{error}</div>}
        <button className="btn btn-primary block" disabled={busy}>{busy ? "Logging in…" : "Log in"}</button>
      </form>
      <p className="muted">
        <Link href="/forgot-password">Forgot password?</Link> · New here? <Link href="/register">Register</Link>
      </p>
    </main>
  );
}
