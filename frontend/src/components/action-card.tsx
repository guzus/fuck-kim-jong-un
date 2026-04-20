import { useEffect, useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { useConnection, useWriteContract, useWaitForTransactionReceipt, useChainId } from "wagmi";
import { mainnet } from "wagmi/chains";

import { Button } from "@/components/ui/button";
import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
} from "@/components/ui/card";
import { KIM_JONG_UN_ADDRESS, kimJongUnAbi } from "@/lib/contract";
import { useConnectModal } from "@/lib/connect-modal";
import { EmojiRain, FaceStamp, type ReactionKind } from "@/components/reaction";

type Action = "pig" | "fuck";

const CLICK_TOASTS: Record<Action, { title: string; description: string }> = {
  pig: {
    title: "Pig snout stamped on the Supreme Leader 🐖",
    description: "Sign in your wallet to make it onchain-permanent.",
  },
  fuck: {
    title: "Middle finger delivered to the Supreme Leader 🖕",
    description: "Sign in your wallet to make it onchain-permanent.",
  },
};

const CONFIRM_TOASTS: Record<Action, string> = {
  pig: "pig() confirmed — Kim officially piggified 🐷",
  fuck: "fuck() confirmed — the Supreme Leader has been served 🖕",
};

export function ActionCard() {
  const { address, status } = useConnection();
  const chainId = useChainId();
  const queryClient = useQueryClient();
  const { openConnectModal } = useConnectModal();

  const [reaction, setReaction] = useState<ReactionKind | null>(null);
  const [rainTick, setRainTick] = useState<ReactionKind | null>(null);

  const { writeContract, data: hash, isPending, variables, reset } = useWriteContract();

  const {
    isLoading: isConfirming,
    isSuccess: isConfirmed,
    error: receiptError,
  } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isConfirmed && hash && variables?.functionName) {
      const fn = variables.functionName as Action;
      toast.success(CONFIRM_TOASTS[fn], {
        description: `${hash.slice(0, 10)}…${hash.slice(-8)}`,
      });
      // Re-trigger rain on confirmation for a celebratory second beat.
      setRainTick(fn);
      queryClient.invalidateQueries();
      reset();
    }
  }, [isConfirmed, hash, variables, queryClient, reset]);

  useEffect(() => {
    if (receiptError) toast.error(receiptError.message);
  }, [receiptError]);

  const triggerReaction = (kind: ReactionKind) => {
    setReaction(kind);
    setRainTick(kind);
    // Auto-clear stamp so the image returns to normal.
    setTimeout(() => setReaction(null), 1100);
  };

  const onAction = (action: Action) => {
    triggerReaction(action);

    if (status !== "connected" || !address) {
      toast.info("Connect a wallet to continue", {
        description: "You'll sign the transaction from your wallet.",
        action: { label: "Connect", onClick: openConnectModal },
      });
      openConnectModal();
      return;
    }
    if (chainId !== mainnet.id) {
      toast.error("Switch to Ethereum mainnet");
      return;
    }

    const copy = CLICK_TOASTS[action];
    toast(copy.title, { description: copy.description });

    writeContract(
      {
        address: KIM_JONG_UN_ADDRESS,
        abi: kimJongUnAbi,
        functionName: action,
      },
      {
        onError: (err) => toast.error(err.message),
        onSuccess: (h) =>
          toast(`${action}() submitted`, {
            description: `${h.slice(0, 10)}…${h.slice(-8)}`,
          }),
      },
    );
  };

  const pendingFn = isPending || isConfirming ? variables?.functionName : undefined;
  const busy = isPending || isConfirming;

  return (
    <>
      <Card>
        <CardHeader>
          <CardTitle>Prove you're not a DPRK hacker</CardTitle>
          <CardDescription>
            Call <code className="font-mono text-xs">pig()</code> and{" "}
            <code className="font-mono text-xs">fuck()</code> on the registry. Each call marks you
            as <code className="font-mono text-xs">isRegardedAsNotNorthKoreanHackerActor</code>.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <div className="relative mx-auto mb-4 w-48 sm:w-56">
            <img
              src="/kim.webp"
              alt="The subject of your symbolic act of dissent."
              width={600}
              height={732}
              className={
                "w-full h-auto rounded-lg ring-1 ring-foreground/10 will-change-transform " +
                (reaction ? "animate-kim-wiggle" : "")
              }
            />
            <FaceStamp kind={reaction} />
          </div>
          <div className="grid grid-cols-2 gap-3">
            <Button
              variant="default"
              disabled={busy}
              onClick={() => onAction("pig")}
            >
              {pendingFn === "pig" ? (isConfirming ? "Confirming…" : "Sending…") : "pig()"}
            </Button>
            <Button
              variant="destructive"
              disabled={busy}
              onClick={() => onAction("fuck")}
            >
              {pendingFn === "fuck" ? (isConfirming ? "Confirming…" : "Sending…") : "fuck()"}
            </Button>
          </div>
          {hash ? (
            <p className="mt-3 text-xs text-muted-foreground break-all">
              tx:{" "}
              <a
                className="underline"
                target="_blank"
                rel="noreferrer"
                href={`https://etherscan.io/tx/${hash}`}
              >
                {hash}
              </a>
            </p>
          ) : null}
        </CardContent>
      </Card>
      <EmojiRain kind={rainTick} />
    </>
  );
}
