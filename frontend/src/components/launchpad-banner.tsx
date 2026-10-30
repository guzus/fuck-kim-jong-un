import { ArrowRight } from "lucide-react";

import { Link } from "@/components/link";
import { buttonVariants } from "@/components/ui/button";
import { chainLabel, launchpadConfig } from "@/lib/launchpad/config";
import { routes } from "@/lib/router";
import { cn } from "@/lib/utils";

/** Launchpad promo on the Lazarus Checker page. */
export function LaunchpadBanner() {
  const live = launchpadConfig.isDeployed;
  const network = chainLabel(launchpadConfig.chain);

  return (
    <section
      aria-labelledby="launchpad-banner-title"
      className="relative overflow-hidden rounded-xl bg-gradient-to-br from-red-500/10 via-background to-blue-500/10 p-5 ring-1 ring-foreground/10 sm:p-6"
    >
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex max-w-2xl flex-col gap-2">
          <span className="text-[11px] font-semibold uppercase tracking-widest text-red-600 dark:text-red-400">
            {live ? `New on ${network}` : `Coming soon to ${network}`}
          </span>
          <h2
            id="launchpad-banner-title"
            className="font-heading text-xl font-semibold tracking-tight sm:text-2xl"
          >
            The memecoin launchpad Lazarus can&apos;t buy into
          </h2>
          <p className="text-sm text-muted-foreground">
            No DPRK operator will insult the Supreme Leader on-chain. So on {network}, only wallets
            that called <code className="font-mono text-xs">pig()</code> and{" "}
            <code className="font-mono text-xs">fuck()</code> can claim the soulbound Not-Lazarus
            Pass, and only pass holders can launch or buy. Curves graduate straight to PancakeSwap.
          </p>
        </div>
        <Link
          href={routes.launchpad}
          className={cn(buttonVariants({ size: "lg" }), "shrink-0 px-4")}
        >
          {live ? "Open the launchpad" : "Preview the launchpad"}
          <ArrowRight />
        </Link>
      </div>
    </section>
  );
}
