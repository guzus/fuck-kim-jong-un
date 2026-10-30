import type { ReactNode } from "react";
import { ExternalLink, TriangleAlert } from "lucide-react";

import { ConnectWallet } from "@/components/connect-wallet";
import { Link } from "@/components/link";
import { SiteNav } from "@/components/site-nav";
import { buttonVariants } from "@/components/ui/button";
import { chainLabel, explorerUrl, launchpadConfig } from "@/lib/launchpad/config";
import { shortAddress } from "@/lib/launchpad/format";
import { useLaunchpadAddresses } from "@/lib/launchpad/hooks";
import { routes } from "@/lib/router";

const network = chainLabel(launchpadConfig.chain);

function NetworkChip() {
  return (
    <span className="inline-flex items-center gap-1.5 rounded-full border border-border bg-muted/40 px-2.5 py-1 text-xs text-muted-foreground">
      <span className="size-1.5 rounded-full bg-amber-500" aria-hidden />
      {network}
    </span>
  );
}

const HOW_IT_WORKS = [
  { title: "Insult Kim", body: `Call pig() and fuck() on the KimJongUn registry on ${network}.` },
  { title: "Claim the pass", body: "Mint the soulbound Not-Lazarus Pass. One per wallet, no transfers." },
  { title: "Launch or buy", body: "Only pass holders can create tokens or buy from a bonding curve." },
  { title: "Graduate", body: "A sold-out curve seeds PancakeSwap V2 in the same transaction and burns the LP." },
];

function NotDeployed() {
  const { problems, chainValid } = launchpadConfig;
  return (
    <section className="flex flex-col gap-4 rounded-xl border border-dashed border-border bg-muted/20 p-6 sm:p-8">
      <span className="text-[11px] font-semibold uppercase tracking-widest text-red-600 dark:text-red-400">
        Not deployed yet
      </span>
      <h2 className="font-heading text-2xl font-semibold tracking-tight">
        {chainValid
          ? `The launchpad isn't deployed on ${network} yet.`
          : "The launchpad network isn't configured correctly."}
      </h2>
      <p className="max-w-2xl text-sm text-muted-foreground">
        The contracts are still being built and audited. Once they&apos;re live, this is where you
        insult Kim on {network}, claim your Not-Lazarus Pass, and launch tokens that Lazarus
        can&apos;t buy. Until then, the original Lazarus Checker on Ethereum is open for business.
      </p>
      <ol className="grid gap-3 text-sm sm:grid-cols-2 lg:grid-cols-4">
        {HOW_IT_WORKS.map((step, i) => (
          <li key={step.title} className="flex flex-col gap-1 rounded-lg bg-background p-3 ring-1 ring-foreground/10">
            <span className="font-mono text-xs text-muted-foreground">{i + 1}</span>
            <span className="font-medium">{step.title}</span>
            <span className="text-xs text-muted-foreground">{step.body}</span>
          </li>
        ))}
      </ol>
      {problems.length > 0 ? (
        <ul className="list-disc pl-5 text-xs text-muted-foreground">
          {problems.map((p) => (
            <li key={p}>{p}</li>
          ))}
        </ul>
      ) : null}
      <div>
        <Link href={routes.home} className={buttonVariants({ variant: "outline" })}>
          Insult Kim on Ethereum instead
        </Link>
      </div>
    </section>
  );
}

function ConfigWarnings() {
  const { warnings, error, launchpad } = useLaunchpadAddresses();
  if (!error && warnings.length === 0) return null;
  return (
    <div className="flex gap-2 rounded-lg border border-amber-500/40 bg-amber-500/10 p-3 text-xs text-amber-900 dark:text-amber-200">
      <TriangleAlert className="mt-0.5 size-4 shrink-0" />
      <div className="flex flex-col gap-1">
        {error && launchpad ? (
          <p>
            The launchpad address {shortAddress(launchpad)} isn&apos;t answering on {network}. Check
            VITE_DPRK_LAUNCHPAD_ADDRESS and VITE_LAUNCHPAD_CHAIN_ID.
          </p>
        ) : null}
        {warnings.map((w) => (
          <p key={w}>{w}</p>
        ))}
      </div>
    </div>
  );
}

function Footer() {
  const launchpad = launchpadConfig.addresses.launchpad;
  const href = launchpad ? explorerUrl("address", launchpad) : undefined;
  return (
    <footer className="flex flex-col gap-2 border-t border-border pt-6 text-xs text-muted-foreground">
      <p>
        Unaudited contracts in active development. Memecoins can go to zero; nothing here is
        financial advice. Pass-gating keeps out people unwilling to insult Kim, not people who are
        merely bad at trading.
      </p>
      {launchpad ? (
        <p className="flex flex-wrap items-center gap-1.5">
          <span className="uppercase tracking-widest text-[10px]">Launchpad</span>
          {href ? (
            <a
              className="inline-flex items-center gap-1 font-mono underline-offset-4 hover:text-foreground hover:underline"
              href={href}
              target="_blank"
              rel="noopener noreferrer"
            >
              {launchpad}
              <ExternalLink className="size-3" />
            </a>
          ) : (
            <span className="font-mono">{launchpad}</span>
          )}
          <span>on {network}</span>
        </p>
      ) : null}
    </footer>
  );
}

/**
 * Layout for every /launchpad route: nav, wallet control on the launchpad chain, deployment guard.
 * `hero` always renders; `children` only when the launchpad is configured for this network.
 */
export function LaunchpadShell({ hero, children }: { hero?: ReactNode; children: ReactNode }) {
  return (
    <main className="min-h-svh w-full bg-background text-foreground">
      <div className="mx-auto flex w-full max-w-5xl flex-col gap-8 px-4 py-6 sm:px-6 sm:py-10">
        <header className="flex flex-wrap items-center justify-between gap-3">
          <SiteNav active="launchpad" />
          <div className="flex flex-wrap items-center justify-end gap-2">
            <NetworkChip />
            <ConnectWallet targetChain={launchpadConfig.chain} targetLabel={network} />
          </div>
        </header>
        {hero}
        {launchpadConfig.isDeployed ? (
          <>
            <ConfigWarnings />
            {children}
          </>
        ) : (
          <NotDeployed />
        )}
        <Footer />
      </div>
    </main>
  );
}
