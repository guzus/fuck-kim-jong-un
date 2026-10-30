import { useId, useState } from "react";
import { Settings2 } from "lucide-react";

import { Input } from "@/components/ui/input";
import { cn } from "@/lib/utils";

const PRESETS = [50, 100, 200, 500];

export const MIN_SLIPPAGE_BPS = 1;
export const MAX_SLIPPAGE_BPS = 5_000;

/** Slippage tolerance and deadline. Both are applied when the transaction is built, not when quoted. */
export function TradeSettings({
  slippageBps,
  onSlippageBps,
  deadlineMinutes,
  onDeadlineMinutes,
}: {
  slippageBps: number;
  onSlippageBps: (bps: number) => void;
  deadlineMinutes: number;
  onDeadlineMinutes: (minutes: number) => void;
}) {
  const [open, setOpen] = useState(false);
  const [customSlippage, setCustomSlippage] = useState("");
  const [deadlineText, setDeadlineText] = useState(String(deadlineMinutes));
  const id = useId();

  const onCustom = (text: string) => {
    setCustomSlippage(text);
    const pct = Number(text);
    if (text.trim() !== "" && Number.isFinite(pct)) {
      const bps = Math.round(pct * 100);
      if (bps >= MIN_SLIPPAGE_BPS && bps <= MAX_SLIPPAGE_BPS) onSlippageBps(bps);
    }
  };

  const onDeadline = (text: string) => {
    setDeadlineText(text);
    const minutes = Number(text);
    if (Number.isInteger(minutes) && minutes >= 1 && minutes <= 60) onDeadlineMinutes(minutes);
  };

  return (
    <div className="flex flex-col gap-2 text-xs">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        aria-controls={`${id}-panel`}
        className="inline-flex w-fit items-center gap-1.5 text-muted-foreground hover:text-foreground"
      >
        <Settings2 className="size-3.5" />
        Slippage {slippageBps / 100}% · deadline {deadlineMinutes} min
      </button>
      {open ? (
        <div id={`${id}-panel`} className="flex flex-col gap-3 rounded-lg bg-muted/40 p-3">
          <div className="flex flex-col gap-1.5">
            <span className="font-medium text-foreground">Max slippage</span>
            <div className="flex flex-wrap items-center gap-1.5">
              {PRESETS.map((bps) => (
                <button
                  key={bps}
                  type="button"
                  onClick={() => {
                    setCustomSlippage("");
                    onSlippageBps(bps);
                  }}
                  className={cn(
                    "rounded-md px-2 py-1 ring-1 ring-foreground/10",
                    slippageBps === bps && customSlippage === ""
                      ? "bg-foreground text-background"
                      : "bg-background hover:bg-muted",
                  )}
                >
                  {bps / 100}%
                </button>
              ))}
              <div className="flex items-center gap-1">
                <Input
                  aria-label="Custom slippage percent"
                  inputMode="decimal"
                  placeholder="Custom"
                  value={customSlippage}
                  onChange={(e) => onCustom(e.target.value)}
                  className="h-7 w-20 text-xs"
                />
                <span>%</span>
              </div>
            </div>
            {slippageBps > 500 ? (
              <span className="text-amber-700 dark:text-amber-400">
                High slippage: a sandwich bot can take most of that.
              </span>
            ) : null}
          </div>
          <label className="flex items-center gap-2">
            <span className="font-medium text-foreground">Deadline</span>
            <Input
              inputMode="numeric"
              value={deadlineText}
              onChange={(e) => onDeadline(e.target.value)}
              className="h-7 w-16 text-xs"
            />
            <span>minutes after you submit</span>
          </label>
        </div>
      ) : null}
    </div>
  );
}
