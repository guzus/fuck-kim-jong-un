import { ExternalLink } from "lucide-react";

import { ActionCard } from "@/components/action-card";
import { ConnectWallet } from "@/components/connect-wallet";
import { GlobalStats } from "@/components/global-stats";
import { UserStats } from "@/components/user-stats";
import { Separator } from "@/components/ui/separator";
import { Toaster } from "@/components/ui/sonner";
import { Providers } from "@/providers";
import { KIM_JONG_UN_ADDRESS } from "@/lib/contract";

const REPO_URL = "https://github.com/guzus/fuck-kim-jong-un";

function GithubIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 16 16" className={className} aria-hidden="true" fill="currentColor">
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82a7.6 7.6 0 0 1 4 0c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"
      />
    </svg>
  );
}

function TopBar() {
  return (
    <div className="flex flex-wrap items-center justify-between gap-3 text-xs text-muted-foreground">
      <a
        href={REPO_URL}
        target="_blank"
        rel="noreferrer"
        className="inline-flex items-center gap-2 hover:text-foreground transition-colors"
      >
        <GithubIcon className="size-4" />
        <span className="font-mono">guzus/fuck-kim-jong-un</span>
      </a>
      <a
        href={`https://etherscan.io/address/${KIM_JONG_UN_ADDRESS}`}
        target="_blank"
        rel="noreferrer"
        className="inline-flex items-center gap-2 hover:text-foreground transition-colors"
      >
        <span className="hidden sm:inline text-[10px] uppercase tracking-widest">Contract</span>
        <span className="font-mono">{KIM_JONG_UN_ADDRESS}</span>
        <ExternalLink className="size-3" />
      </a>
    </div>
  );
}

function App() {
  return (
    <Providers>
      <main className="min-h-svh w-full bg-background text-foreground">
        <div className="mx-auto w-full max-w-4xl px-6 py-6 sm:py-10 flex flex-col gap-8">
          <TopBar />
          <header className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4">
            <div className="flex flex-col gap-3">
              <h1 className="font-heading text-5xl sm:text-6xl lg:text-7xl font-bold tracking-tight leading-[1.05]">
                <span className="text-red-600 dark:text-red-500">DPRK</span>
                <span className="text-muted-foreground">.</span>
                <span className="text-blue-600 dark:text-blue-500">FUN</span>
                <span className="block text-foreground text-3xl sm:text-4xl lg:text-5xl font-semibold mt-1">
                  Lazarus Checker
                </span>
              </h1>
              <p className="text-muted-foreground max-w-xl text-base sm:text-lg">
                Publicly declare that you are not a North Korean hacker by calling{" "}
                <code className="font-mono text-sm">pig()</code> and{" "}
                <code className="font-mono text-sm">fuck()</code> on the on-chain registry.
                Both calls qualify you for the{" "}
                <code className="font-mono text-sm">hasPiggedAndFuckedKimJongUn</code> gate used
                by the Uniswap v4 eligibility hook.
              </p>
            </div>
            <ConnectWallet />
          </header>

          <Separator />

          <GlobalStats />
          <ActionCard />
          <UserStats />

          <footer className="flex flex-col gap-3 pt-6 border-t border-border">
            <img
              src="/dprk-hackers.webp"
              alt="State-sponsored operators at workstations — the archetype of the threat model this contract targets."
              width={1200}
              height={675}
              loading="lazy"
              className="w-full h-auto rounded-xl ring-1 ring-foreground/10 object-cover aspect-[16/9]"
            />
            <h2 className="font-heading text-lg font-semibold tracking-tight text-foreground">
              DeFi builders: gate your protocol with this
            </h2>
            <p className="text-sm text-muted-foreground">
              The Lazarus Group has drained more than a billion dollars from crypto protocols
              and laundered the proceeds straight into the DPRK weapons program. If you are
              shipping DeFi, you should care who touches your contracts — without forcing
              every legitimate user through invasive KYC.
            </p>
            <p className="text-sm text-muted-foreground">
              <code className="font-mono text-xs">hasPiggedAndFuckedKimJongUn(address)</code>{" "}
              is a cheap, onchain, self-attested humanity proof: a DPRK operator acting on
              behalf of the regime will not perform a symbolic act of dissent against their
              head of state. Wire it into your eligibility checks and you get Lazarus-resistance
              for one <code className="font-mono text-xs">SLOAD</code>.
            </p>
            <pre className="text-xs bg-muted/40 rounded-md p-3 overflow-x-auto font-mono leading-relaxed">
{`interface IKimJongUn {
    function hasPiggedAndFuckedKimJongUn(address) external view returns (bool);
}

IKimJongUn verifier = IKimJongUn(${KIM_JONG_UN_ADDRESS});
require(verifier.hasPiggedAndFuckedKimJongUn(user), "Lazarus");`}
            </pre>
            <p className="text-sm text-muted-foreground">
              A working Uniswap v4 eligibility hook ships in the repo as a reference
              integration. Fork, audit, deploy — the verifier itself is immutable,
              storage-only, and already live on mainnet.
            </p>
            <div className="flex flex-wrap gap-4 text-xs pt-1">
              <a
                className="underline text-muted-foreground hover:text-foreground"
                target="_blank"
                rel="noreferrer"
                href="https://github.com/guzus/fuck-kim-jong-un"
              >
                GitHub repo
              </a>
              <a
                className="underline text-muted-foreground hover:text-foreground font-mono"
                target="_blank"
                rel="noreferrer"
                href={`https://etherscan.io/address/${KIM_JONG_UN_ADDRESS}`}
              >
                {KIM_JONG_UN_ADDRESS}
              </a>
            </div>
          </footer>
        </div>
      </main>
      <Toaster richColors position="top-right" />
    </Providers>
  );
}

export default App;
