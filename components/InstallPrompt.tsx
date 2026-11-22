"use client";
import { useEffect, useState } from "react";

interface InstallEvent extends Event {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

export default function InstallPrompt() {
  const [evt, setEvt] = useState<InstallEvent | null>(null);
  const [ios, setIos] = useState(false);
  const [hidden, setHidden] = useState(true);

  useEffect(() => {
    const standalone =
      window.matchMedia("(display-mode: standalone)").matches ||
      (navigator as unknown as { standalone?: boolean }).standalone === true;
    if (standalone || localStorage.getItem("lga-install-dismissed")) return;
    const isIos = /iphone|ipad|ipod/i.test(navigator.userAgent);
    setIos(isIos);
    setHidden(false);
    const onPrompt = (e: Event) => {
      e.preventDefault();
      setEvt(e as InstallEvent);
    };
    window.addEventListener("beforeinstallprompt", onPrompt);
    return () => window.removeEventListener("beforeinstallprompt", onPrompt);
  }, []);

  function dismiss() {
    localStorage.setItem("lga-install-dismissed", "1");
    setHidden(true);
  }

  if (hidden || (!evt && !ios)) return null;
  return (
    <div className="banner install">
      <div>
        <strong>Install the app</strong>
        <div className="muted">
          {evt ? "Add Light Growth Academy to your home screen." : "Tap Share, then “Add to Home Screen”."}
        </div>
      </div>
      <div className="row">
        {evt && (
          <button
            className="btn btn-primary small"
            onClick={async () => {
              await evt.prompt();
              await evt.userChoice;
              setEvt(null);
              dismiss();
            }}
          >
            Install
          </button>
        )}
        <button className="btn small" onClick={dismiss} aria-label="Dismiss install message">
          Not now
        </button>
      </div>
    </div>
  );
}
