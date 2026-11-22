"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

export default function ResetPassword() {
  const router = useRouter();
  const [error, setError] = useState<string | null>(null);

  async function onSubmit(e: React.FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const pw = String(f.get("password"));
    if (pw.length < 8) return setError("Use at least 8 characters.");
    if (pw !== String(f.get("confirm"))) return setError("The two passwords do not match.");
    const { error } = await createClient().auth.updateUser({ password: pw });
    if (error) return setError(error.message);
    router.replace("/today");
    router.refresh();
  }

  return (
    <main className="page narrow stack">
      <h1>Choose a new password</h1>
      <form className="card stack" onSubmit={onSubmit}>
        <label className="field"><span>New password</span><input name="password" type="password" autoComplete="new-password" required /></label>
        <label className="field"><span>Confirm password</span><input name="confirm" type="password" autoComplete="new-password" required /></label>
        {error && <div className="banner error" role="alert">{error}</div>}
        <button className="btn btn-primary block">Save password</button>
      </form>
    </main>
  );
}
