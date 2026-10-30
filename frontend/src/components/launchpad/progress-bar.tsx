import { cn } from "@/lib/utils";

/** Bonding-curve progress, 0–10 000 bps. */
export function CurveProgress({
  bps,
  graduated,
  className,
}: {
  bps: number;
  graduated?: boolean;
  className?: string;
}) {
  const pct = Math.min(Math.max(bps / 100, 0), 100);
  return (
    <div
      role="progressbar"
      aria-label="Bonding curve progress"
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(pct)}
      className={cn("h-2 w-full overflow-hidden rounded-full bg-muted", className)}
    >
      <div
        className={cn(
          "h-full rounded-full transition-[width] duration-500",
          graduated ? "bg-blue-600" : "bg-gradient-to-r from-red-500 to-blue-600",
        )}
        style={{ width: `${pct}%` }}
      />
    </div>
  );
}
