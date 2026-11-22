import Link from "next/link";
import { createClient } from "@/lib/supabase/server";

export default async function Home() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  return (
    <main className="page narrow stack">
      <div className="logo">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img src="/icons/icon-192.png" alt="" width={40} height={40} />
        Light Growth Academy
      </div>
      <section className="hero stack">
        <h1>Growing in the Word. Walking in the light.</h1>
        <p className="muted">
          Simple daily spiritual tasks, honest reporting, and people who walk with you. Four levels, one step at a
          time.
        </p>
        {user ? (
          <Link className="btn btn-primary block" href="/today" style={{ textAlign: "center", lineHeight: "28px" }}>
            Go to my dashboard
          </Link>
        ) : (
          <div className="row">
            <Link className="btn btn-primary" href="/register" style={{ flex: 1, textAlign: "center", lineHeight: "28px" }}>
              Register
            </Link>
            <Link className="btn" href="/login" style={{ flex: 1, textAlign: "center", lineHeight: "28px" }}>
              Log in
            </Link>
          </div>
        )}
      </section>
    </main>
  );
}
