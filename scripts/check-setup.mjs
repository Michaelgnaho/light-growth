// Checks that .env.local is filled in and that your online Supabase project is reachable
// and has the Academy tables. Run:  npm run check
import { existsSync, readFileSync } from "node:fs";

const fail = (m) => { console.error("✗ " + m); process.exit(1); };
if (!existsSync(".env.local")) fail("There is no .env.local file. Copy .env.example to .env.local and fill in both values.");
const env = Object.fromEntries(
  readFileSync(".env.local", "utf8").split(/\r?\n/)
    .map((l) => l.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/)).filter(Boolean)
    .map((m) => [m[1], m[2].replace(/^["']|["']$/g, "")]),
);
const url = env.NEXT_PUBLIC_SUPABASE_URL;
const key = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
const ok = (m) => console.log("✓ " + m);

if (!url || url.includes("YOUR-PROJECT")) fail("NEXT_PUBLIC_SUPABASE_URL is not set in .env.local");
if (!key || key.includes("YOUR-")) fail("NEXT_PUBLIC_SUPABASE_ANON_KEY is not set in .env.local");
if (!/^https:\/\/[a-z0-9-]+\.supabase\.co\/?$/.test(url)) console.warn("! The URL does not look like https://<ref>.supabase.co, double-check it.");
ok(".env.local has both values");

const headers = { apikey: key, Authorization: `Bearer ${key}` };
let res;
try { res = await fetch(`${url}/rest/v1/levels?select=level,name&order=level`, { headers }); }
catch (e) { fail("Could not reach Supabase: " + e.message); }
if (res.status === 401 || res.status === 403) fail("Supabase rejected the key. Copy the anon / publishable key again.");
if (res.status === 404) fail("The levels table was not found. Run: npm run db:push");
if (!res.ok) fail(`Unexpected answer from Supabase (${res.status}): ${await res.text()}`);
const levels = await res.json();
if (levels.length !== 4) fail(`Expected 4 levels, found ${levels.length}. Run: npm run db:push`);
ok("Supabase is reachable and the database is set up (4 levels found)");

const v = await fetch(`${url}/rest/v1/rpc/voice_notes_enabled`, { method: "POST", headers: { ...headers, "Content-Type": "application/json" }, body: "{}" });
if (v.ok) ok(`Voice notes are ${(await v.json()) ? "ON" : "OFF"}`);
else fail("voice_notes_enabled() is missing. Run: npm run db:push");
console.log("\nAll good. Start the app with: npm run dev");
