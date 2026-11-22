"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";

export default function TabBar({ showReflections }: { showReflections: boolean }) {
  const path = usePathname();
  const tabs = [
    { href: "/today", label: "Today" },
    { href: "/buddy", label: "My buddy" },
    ...(showReflections ? [{ href: "/reflections", label: "Reflections" }] : []),
    { href: "/reminders", label: "Reminders" },
  ];
  return (
    <nav className="tabbar" aria-label="Main" style={{ gridTemplateColumns: `repeat(${tabs.length}, 1fr)` }}>
      {tabs.map((t) => (
        <Link key={t.href} href={t.href} aria-current={path === t.href ? "page" : undefined}>
          {t.label}
        </Link>
      ))}
    </nav>
  );
}
