"use client";
import { useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";

export default function ForgotPassword() {
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const email = String(new FormData(e.currentTarget).get("email")).trim();
    const { error } = await createClient().auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/auth/confirm?next=/reset-password`,
    });
    if (error) setError(error.message);
    else setSent(true); // same message whether or not the email exists
  }

  return (
    <main className="page narrow stack">
      <h1>Reset your password</h1>
      {sent ? (
        <p>If that email is registered, a reset link is on its way.</p>
      ) : (
        <form className="card stack" onSubmit={onSubmit}>
          <label className="field"><span>Email</span><input name="email" type="email" required /></label>
          {error && <div className="banner error" role="alert">{error}</div>}
          <button className="btn btn-primary block">Send reset link</button>
        </form>
      )}
      <Link href="/login">Back to log in</Link>
    </main>
  );
}
