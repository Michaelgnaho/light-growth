import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

// Pages that need a signed-in user. Authorisation itself is enforced by RLS and the database functions.
const PROTECTED = ["/today", "/buddy", "/reflections", "/reminders"];

export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    console.error("Missing Supabase env vars", {
      hasUrl: !!url,
      hasKey: !!key,
    });
    return NextResponse.next({ request });
  }
  const supabase = createServerClient(url, key, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(list) {
        list.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        list.forEach(({ name, value, options }) =>
          response.cookies.set(name, value, options),
        );
      },
    },
  });

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const path = request.nextUrl.pathname;

  const redirect = (to: string, search?: Record<string, string>) => {
    const url = request.nextUrl.clone();
    url.pathname = to;
    url.search = search ? new URLSearchParams(search).toString() : "";
    const res = NextResponse.redirect(url);
    response.cookies.getAll().forEach((c) => res.cookies.set(c));
    return res;
  };

  if (!user && PROTECTED.some((p) => path === p || path.startsWith(p + "/"))) {
    return redirect("/login", { next: path });
  }
  if (user && (path === "/login" || path === "/register")) {
    return redirect("/today");
  }
  return response;
}
