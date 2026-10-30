import { ArrowRight, Lock } from "lucide-react";

import { Link } from "@/components/link";
import { LaunchpadShell } from "@/components/launchpad/launchpad-shell";
import { PassPanel } from "@/components/launchpad/pass-panel";
import { TokenGrid } from "@/components/launchpad/token-grid";
import { buttonVariants } from "@/components/ui/button";
import { chainLabel, launchpadConfig } from "@/lib/launchpad/config";
import { formatAmount } from "@/lib/launchpad/format";
import { useLaunchpadConstants, useLaunchpadWallet, usePassStatus } from "@/lib/launchpad/hooks";
import { routes } from "@/lib/router";
import { useDocumentTitle } from "@/lib/use-document-title";
import { cn } from "@/lib/utils";

const network = chainLabel(launchpadConfig.chain);

function Hero() {
  const { constants } = useLaunchpadConstants();
  return (
    <section className="flex flex-col gap-3">
      <h1 className="font-heading text-5xl font-bold leading-[1.05] tracking-tight sm:text-6xl">
        <span className="text-red-600 dark:text-red-500">DPRK</span>
        <span className="text-muted-foreground">.</span>
        <span className="text-blue-600 dark:text-blue-500">FUN</span>
        <span className="mt-1 block text-3xl font-semibold text-foreground sm:text-4xl">Launchpad</span>
      </h1>
      <p className="max-w-2xl text-base text-muted-foreground sm:text-lg">
        Memecoins that only non-Lazarus wallets can buy. Insult Kim on {network}, claim your soulbound
        pass, then launch or buy on a bonding curve that graduates to PancakeSwap
        {constants ? ` once it raises ${formatAmount(constants.graduationBnb)} ${launchpadConfig.nativeSymbol}` : ""}.
      </p>
    </section>
  );
}

function TokensHeader() {
  const { account } = useLaunchpadWallet();
  const { certified } = usePassStatus(account);
  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 className="font-heading text-2xl font-semibold tracking-tight">Tokens</h2>
          <p className="text-sm text-muted-foreground">Newest first. Every buyer has insulted Kim.</p>
        </div>
        <Link href={routes.create} className={cn(buttonVariants({ size: "lg" }), "px-4")}>
          Launch a token
          <ArrowRight />
        </Link>
      </div>
      {certified === true ? null : (
        <div className="flex items-start gap-2 rounded-lg border border-red-500/30 bg-red-500/5 p-3 text-sm">
          <Lock className="mt-0.5 size-4 shrink-0 text-red-600 dark:text-red-400" />
          <p className="text-muted-foreground">
            <span className="font-medium text-foreground">Pass holders only.</span> Launching and
            buying need a Not-Lazarus Pass, so insult Kim above first. Browsing is free, and selling
            back to a curve is always open.
          </p>
        </div>
      )}
    </div>
  );
}

export default function LaunchpadPage() {
  useDocumentTitle("Launchpad · DPRK.FUN");
  return (
    <LaunchpadShell hero={<Hero />}>
      <PassPanel />
      <section className="flex flex-col gap-4">
        <TokensHeader />
        <TokenGrid />
      </section>
    </LaunchpadShell>
  );
}
