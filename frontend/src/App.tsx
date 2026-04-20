import { ActionCard } from "@/components/action-card";
import { ConnectWallet } from "@/components/connect-wallet";
import { GlobalStats } from "@/components/global-stats";
import { UserStats } from "@/components/user-stats";
import { Separator } from "@/components/ui/separator";
import { Toaster } from "@/components/ui/sonner";
import { Providers } from "@/providers";
import { KIM_JONG_UN_ADDRESS } from "@/lib/contract";

function App() {
  return (
    <Providers>
      <main className="min-h-svh w-full bg-background text-foreground">
        <div className="mx-auto w-full max-w-4xl px-6 py-10 sm:py-16 flex flex-col gap-8">
          <header className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-4">
            <div className="flex flex-col gap-2">
              <h1 className="font-heading text-3xl sm:text-4xl font-semibold tracking-tight">
                <span className="text-red-600 dark:text-red-500">DPRK</span>
                <span className="text-muted-foreground">.</span>
                <span className="text-blue-600 dark:text-blue-500">FUN</span>
                <span className="text-muted-foreground">:</span> Lazarus Checker
              </h1>
              <p className="text-muted-foreground max-w-xl text-sm sm:text-base">
                Publicly declare that you are not a North Korean hacker by calling{" "}
                <code className="font-mono text-xs">pig()</code> and{" "}
                <code className="font-mono text-xs">fuck()</code> on the on-chain registry.
                Both calls qualify you for the{" "}
                <code className="font-mono text-xs">hasPiggedAndFuckedKimJongUn</code> gate used
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
