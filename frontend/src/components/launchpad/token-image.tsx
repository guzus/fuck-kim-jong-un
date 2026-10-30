import { useState } from "react";

import { cn } from "@/lib/utils";

/**
 * Token logo from creator metadata. `src` must already be a vetted https URL (see parseTokenMetadata).
 * No referrer is sent to the image host, and a broken or missing image falls back to a lettered tile.
 */
export function TokenImage({
  src,
  symbol,
  seed,
  className,
}: {
  src: string | undefined;
  symbol: string;
  /** Usually the token address; picks the fallback colour. */
  seed: string;
  className?: string;
}) {
  const [failedSrc, setFailedSrc] = useState<string | undefined>(undefined);
  const hue = Number.parseInt(seed.slice(2, 8), 16) % 360 || 0;

  if (!src || failedSrc === src) {
    const letter = Array.from(symbol.trim())[0]?.toUpperCase() ?? "?";
    return (
      <div
        aria-hidden
        className={cn(
          "flex shrink-0 select-none items-center justify-center overflow-hidden rounded-lg font-heading font-semibold text-foreground/70 ring-1 ring-foreground/10",
          className,
        )}
        style={{ background: `linear-gradient(135deg, hsl(${hue} 80% 90%), hsl(${(hue + 60) % 360} 80% 82%))` }}
      >
        {letter}
      </div>
    );
  }

  return (
    <img
      src={src}
      alt=""
      loading="lazy"
      decoding="async"
      referrerPolicy="no-referrer"
      draggable={false}
      onError={() => setFailedSrc(src)}
      className={cn("shrink-0 overflow-hidden rounded-lg bg-muted object-cover ring-1 ring-foreground/10", className)}
    />
  );
}
