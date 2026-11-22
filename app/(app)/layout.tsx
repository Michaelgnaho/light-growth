import { redirect } from "next/navigation";
import InstallPrompt from "@/components/InstallPrompt";
import SignOutButton from "@/components/SignOutButton";
import TabBar from "@/components/TabBar";
import { createClient } from "@/lib/supabase/server";
import type { Profile } from "@/lib/types";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: profile } = await supabase.from("profiles").select("*").eq("id", user.id).single<Profile>();
  const { data: voiceOn } = await supabase.rpc("voice_notes_enabled");

  if (!profile || profile.status !== "active") {
    const status = profile?.status ?? "pending";
    return (
      <main className="page narrow stack">
        <h1>{status === "pending" ? "Almost there" : "Account unavailable"}</h1>
        <p>
          {status === "pending" &&
            "Your email is verified. An admin will approve your account shortly. You will get a welcome message when it is ready."}
          {status === "suspended" && "Your account is suspended. Please contact your mentor or an admin."}
          {status === "rejected" && "Your registration was not approved. Please contact the Academy team."}
        </p>
        <SignOutButton />
      </main>
    );
  }

  return (
    <>
      <main className="page stack">
        <InstallPrompt />
        {children}
      </main>
      <TabBar showReflections={voiceOn === true} />
    </>
  );
}
