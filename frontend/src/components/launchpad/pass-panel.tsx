import { useMemo, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Check, Lock } from "lucide-react";
import { toast } from "sonner";
import type { Hash } from "viem";
import { simulateContract, writeContract } from "wagmi/actions";

import { WalletGate } from "@/components/launchpad/wallet-gate";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { dprkPassAbi } from "@/lib/abi/launchpad";
import { kimJongUnAbi } from "@/lib/contract";
import { chainLabel, explorerUrl, launchpadConfig } from "@/lib/launchpad/config";
import { describeError } from "@/lib/launchpad/errors";
import { useLaunchpadWallet, usePassStatus } from "@/lib/launchpad/hooks";
import { shortAddress } from "@/lib/launchpad/format";
import { decodePassTokenUri } from "@/lib/launchpad/token-uri";
import { waitForSuccess } from "@/lib/launchpad/tx";
import { wagmiConfig } from "@/lib/wagmi";
import { cn } from "@/lib/utils";

type Step = "pig" | "fuck" | "claim";

const chainId = launchpadConfig.chainId;
const network = chainLabel(launchpadConfig.chain);
const numberFmt = new Intl.NumberFormat("en-US");

const SUCCESS: Record<Step, string> = {
  pig: "pig() confirmed. Kim officially piggified 🐷",
  fuck: "fuck() confirmed. The Supreme Leader has been served 🖕",
  claim: "Not-Lazarus Pass minted. Welcome to the free world.",
};

function txDescription(hash: Hash) {
  return `${hash.slice(0, 10)}…${hash.slice(-8)}`;
}

function StepCard({
  index,
  title,
  body,
  state,
  action,
}: {
  index: number;
  title: ReactNode;
  body: ReactNode;
  state: "done" | "current" | "locked" | "unknown";
  action?: ReactNode;
}) {
  return (
    <li
      className={cn(
        "flex flex-col gap-2 rounded-lg p-3 ring-1",
        state === "done" && "bg-emerald-500/5 ring-emerald-500/30",
        state === "current" && "bg-background ring-foreground/20",
        (state === "locked" || state === "unknown") && "bg-muted/30 ring-foreground/10",
      )}
    >
      <div className="flex items-center justify-between gap-2">
        <span className="font-mono text-xs text-muted-foreground">Step {index}</span>
        {state === "done" ? (
          <span className="inline-flex items-center gap-1 text-xs font-medium text-emerald-600 dark:text-emerald-400">
            <Check className="size-3.5" /> Done
          </span>
        ) : state === "locked" ? (
          <span className="inline-flex items-center gap-1 text-xs text-muted-foreground">
            <Lock className="size-3" /> Locked
          </span>
        ) : null}
      </div>
      <div className="font-mono text-base font-semibold">{title}</div>
      <p className="text-xs text-muted-foreground">{body}</p>
      {action ? <div className="mt-auto pt-1">{action}</div> : null}
    </li>
  );
}

/** Step 1 pig(), step 2 fuck() (on the launchpad chain's registry), step 3 claim() the soulbound pass. */
export function PassPanel() {
  const { account, connected, wrongChain } = useLaunchpadWallet();
  const status = usePassStatus(account);
  const queryClient = useQueryClient();
  const [busy, setBusy] = useState<{ step: Step; label: string } | null>(null);

  const passMeta = useMemo(() => decodePassTokenUri(status.tokenUri), [status.tokenUri]);
  const ready = connected && !wrongChain;
  const known = ready && status.pigged !== undefined;

  async function run(step: Step) {
    if (!account) return;
    const setLabel = (label: string) => setBusy({ step, label });
    setLabel("Simulating…");
    try {
      let hash: Hash;
      if (step === "claim") {
        if (!status.pass) throw new Error("The pass contract address is unknown.");
        const { request } = await simulateContract(wagmiConfig, {
          address: status.pass,
          abi: dprkPassAbi,
          functionName: "claim",
          chainId,
          account,
        });
        setLabel("Confirm in wallet…");
        hash = await writeContract(wagmiConfig, request);
      } else {
        if (!status.kimJongUn) throw new Error("The KimJongUn registry address is unknown.");
        const { request } = await simulateContract(wagmiConfig, {
          address: status.kimJongUn,
          abi: kimJongUnAbi,
          functionName: step === "pig" ? "pig" : "fuck",
          chainId,
          account,
        });
        setLabel("Confirm in wallet…");
        hash = await writeContract(wagmiConfig, request);
      }
      setLabel("Confirming…");
      await waitForSuccess(hash);
      toast.success(SUCCESS[step], { description: txDescription(hash) });
      await queryClient.invalidateQueries();
    } catch (error) {
      toast.error(describeError(error));
    } finally {
      setBusy(null);
    }
  }

  const stepState = (done: boolean | undefined, unlocked: boolean): "done" | "current" | "locked" | "unknown" => {
    if (!known) return "unknown";
    if (done) return "done";
    return unlocked ? "current" : "locked";
  };

  const pigState = stepState(status.pigged, true);
  const fuckState = stepState(status.fucked, true);
  const claimState = stepState(status.certified, Boolean(status.pigged && status.fucked));

  const actionButton = (step: Step, label: string, state: string, variant: "default" | "destructive" = "default") =>
    ready && state !== "done" ? (
      <Button
        className="w-full"
        variant={variant}
        disabled={busy !== null || state === "locked" || state === "unknown"}
        onClick={() => run(step)}
      >
        {busy?.step === step ? busy.label : label}
      </Button>
    ) : null;

  if (ready && status.certified) {
    // Job done: collapse the three steps into a compact certificate so the token grid gets the space.
    return (
      <Card id="pass" data-testid="pass-certified">
        <CardContent className="flex flex-col gap-4 sm:flex-row sm:items-center">
          {/* DprkPass draws a 600x800 poster, so the frame is 3:4. */}
          {passMeta?.image ? (
            <img
              src={passMeta.image}
              alt={`Not-Lazarus Pass #${status.passId?.toString() ?? ""}`}
              className="h-40 w-30 shrink-0 rounded-lg object-contain ring-1 ring-foreground/10"
            />
          ) : (
            <Skeleton className="h-40 w-30 shrink-0" />
          )}
          <div className="flex min-w-0 flex-col gap-1.5">
            <span className="text-[11px] font-semibold uppercase tracking-widest text-emerald-600 dark:text-emerald-400">
              Certified not Lazarus
            </span>
            <h2 className="font-heading text-xl font-semibold tracking-tight">
              Not-Lazarus Pass #{status.passId?.toString()}
            </h2>
            <p className="text-sm text-muted-foreground">
              Soulbound to {account ? shortAddress(account) : "this wallet"}. You can launch tokens and buy from
              any curve on {network}.
            </p>
            <p className="flex flex-wrap items-center gap-x-3 gap-y-1 font-mono text-xs text-muted-foreground">
              {["pig()", "fuck()", "claim()"].map((fn) => (
                <span key={fn} className="inline-flex items-center gap-1">
                  <Check className="size-3 text-emerald-600 dark:text-emerald-400" />
                  {fn}
                </span>
              ))}
              {status.totalClaimed !== undefined ? (
                <span className="font-sans">· {numberFmt.format(status.totalClaimed)} passes claimed</span>
              ) : null}
              {status.pass && explorerUrl("token", status.pass) ? (
                <a
                  className="font-sans underline underline-offset-4 hover:text-foreground"
                  href={explorerUrl("token", status.pass)}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  explorer
                </a>
              ) : null}
            </p>
          </div>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card id="pass">
      <CardHeader>
        <CardTitle className="flex flex-wrap items-baseline justify-between gap-2 text-lg">
          <span>Your Not-Lazarus Pass</span>
          {status.totalClaimed !== undefined ? (
            <span className="text-xs font-normal text-muted-foreground">
              {numberFmt.format(status.totalClaimed)} claimed so far
            </span>
          ) : null}
        </CardTitle>
        <CardDescription>
          No DPRK operator will insult the Supreme Leader on-chain, so three transactions on {network} are
          your proof. Calls on the Ethereum registry don&apos;t count here: the pass checks the {network}{" "}
          registry.
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4 lg:flex-row">
        <div className="flex flex-1 flex-col gap-3">
          <ol className="grid gap-3 sm:grid-cols-3">
            <StepCard
              index={1}
              title="pig()"
              body="Stamp a snout on the Supreme Leader. Permanent, public, on-chain."
              state={pigState}
              action={actionButton("pig", "pig()", pigState)}
            />
            <StepCard
              index={2}
              title="fuck()"
              body="Deliver the finger. Same registry, same permanence."
              state={fuckState}
              action={actionButton("fuck", "fuck()", fuckState, "destructive")}
            />
            <StepCard
              index={3}
              title="claim()"
              body={
                <>
                  Mint the soulbound pass (<span lang="ko">김정은 개새끼</span>). One per wallet, no transfers.
                </>
              }
              state={claimState}
              action={actionButton("claim", "Claim pass", claimState)}
            />
          </ol>
          {!ready ? (
            <div className="flex flex-col gap-2 rounded-lg bg-muted/30 p-3 sm:flex-row sm:items-center sm:justify-between">
              <p className="text-sm text-muted-foreground">
                {connected
                  ? `Switch to ${network} to see your progress.`
                  : "Connect a wallet to see your progress and start insulting."}
              </p>
              <WalletGate className="sm:w-auto" />
            </div>
          ) : status.error ? (
            <p className="text-sm text-destructive">{describeError(status.error)}</p>
          ) : null}
        </div>

        <div className="flex w-full shrink-0 flex-col items-center gap-2 lg:w-56">
          <div className="flex aspect-square w-full max-w-56 flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-border bg-muted/20 p-4 text-center text-xs text-muted-foreground">
            <Lock className="size-5" />
            Your pass shows up here once it&apos;s claimed.
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
