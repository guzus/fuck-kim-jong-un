import { useEffect, useMemo, useState } from "react";

export type ReactionKind = "pig" | "fuck";

const FACE_EMOJI: Record<ReactionKind, string> = {
  pig: "🐽",
  fuck: "🖕",
};

const RAIN_EMOJIS: Record<ReactionKind, string[]> = {
  pig: ["🐖", "🐷", "🐽"],
  fuck: ["🖕", "💢", "🔥"],
};

type Drop = {
  key: string;
  emoji: string;
  left: number;
  drift: number;
  duration: number;
  delay: number;
  size: number;
  spin: number;
};

function buildDrops(kind: ReactionKind, count = 24): Drop[] {
  const pool = RAIN_EMOJIS[kind];
  const drops: Drop[] = [];
  for (let i = 0; i < count; i++) {
    drops.push({
      key: `${kind}-${i}-${Math.random()}`,
      emoji: pool[Math.floor(Math.random() * pool.length)],
      left: Math.random() * 100,
      drift: (Math.random() - 0.5) * 40,
      duration: 1.6 + Math.random() * 1.4,
      delay: Math.random() * 0.35,
      size: 18 + Math.random() * 26,
      spin: (Math.random() < 0.5 ? -1 : 1) * (180 + Math.random() * 540),
    });
  }
  return drops;
}

/** Pig snout / middle finger stamped on Kim's face. Render above the portrait. */
export function FaceStamp({ kind }: { kind: ReactionKind | null }) {
  if (!kind) return null;
  return (
    <div
      key={kind + Date.now()}
      className="pointer-events-none absolute left-1/2 top-[58%] z-10 -translate-x-1/2 -translate-y-1/2 animate-kim-face-stamp text-[88px] leading-none drop-shadow-lg"
      aria-hidden
    >
      {FACE_EMOJI[kind]}
    </div>
  );
}

/** Full-viewport emoji rain. Mounts on reaction, auto-unmounts after animation. */
export function EmojiRain({ kind }: { kind: ReactionKind | null }) {
  const [active, setActive] = useState<ReactionKind | null>(null);
  const drops = useMemo(() => (active ? buildDrops(active) : []), [active]);

  useEffect(() => {
    if (!kind) return;
    setActive(kind);
    const t = setTimeout(() => setActive(null), 3200);
    return () => clearTimeout(t);
  }, [kind]);

  if (!active) return null;

  return (
    <div
      className="pointer-events-none fixed inset-0 z-[60] overflow-hidden"
      aria-hidden
    >
      {drops.map((d) => (
        <span
          key={d.key}
          className="absolute top-0 animate-emoji-fall select-none"
          style={{
            left: `${d.left}%`,
            fontSize: `${d.size}px`,
            animationDuration: `${d.duration}s`,
            animationDelay: `${d.delay}s`,
            ["--x-drift" as string]: `${d.drift}vw`,
            ["--spin" as string]: `${d.spin}deg`,
          }}
        >
          {d.emoji}
        </span>
      ))}
    </div>
  );
}
