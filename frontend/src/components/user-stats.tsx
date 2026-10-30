import { useState } from "react";
import { isAddress, getAddress, type Address } from "viem";
import { useConnection, useReadContracts } from "wagmi";

import { Button } from "@/components/ui/button";
import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Skeleton } from "@/components/ui/skeleton";
import { KIM_JONG_UN_ADDRESS, kimJongUnAbi } from "@/lib/contract";

const numberFmt = new Intl.NumberFormat("en-US");

export function UserStats() {
  const { address: connected } = useConnection();
  const [input, setInput] = useState("");
  const [target, setTarget] = useState<Address | undefined>(undefined);

  // Pre-fill with the connected wallet once. Adjusting state during render (instead of in an effect)
  // is React's recommended pattern and behaves the same: it runs before the frame is committed.
  if (connected && !target) setTarget(connected);

  const valid = isAddress(input);

  const contract = { address: KIM_JONG_UN_ADDRESS, abi: kimJongUnAbi } as const;

  const { data, isLoading, error } = useReadContracts({
    contracts: target
      ? [
          { ...contract, functionName: "pigCalls", args: [target] },
          { ...contract, functionName: "fuckCalls", args: [target] },
          { ...contract, functionName: "hasPiggedAndFuckedKimJongUn", args: [target] },
          {
            ...contract,
            functionName: "isRegardedAsNotNorthKoreanHackerActor",
            args: [target],
          },
        ]
      : [],
    query: { enabled: Boolean(target), refetchInterval: 15_000 },
  });

  const [pigs, fucks, both, flagged] = data ?? [];

  const onLookup = () => {
    if (valid) setTarget(getAddress(input));
  };

  return (
    <Card>
      <CardHeader>
        <CardTitle>Address lookup</CardTitle>
        <CardDescription>
          Check any address against the registry. Pre-fills with your connected wallet.
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        <div className="flex flex-col sm:flex-row gap-2">
          <Input
            placeholder="0x…"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && valid) onLookup();
            }}
            className="font-mono"
          />
          <div className="flex gap-2">
            <Button disabled={!valid} onClick={onLookup}>
              Look up
            </Button>
            {connected ? (
              <Button
                variant="outline"
                onClick={() => {
                  setInput(connected);
                  setTarget(connected);
                }}
              >
                Me
              </Button>
            ) : null}
          </div>
        </div>

        {target ? (
          <div className="flex flex-col gap-3">
            <div className="text-xs text-muted-foreground font-mono break-all">
              Target: {target}
            </div>

            {error ? (
              <p className="text-sm text-destructive">{error.message}</p>
            ) : (
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
                <Stat
                  label="pig() calls"
                  value={pigs?.result}
                  loading={isLoading}
                />
                <Stat
                  label="fuck() calls"
                  value={fucks?.result}
                  loading={isLoading}
                />
                <BoolStat
                  label="Verified"
                  value={flagged?.result}
                  loading={isLoading}
                />
                <BoolStat
                  label="Pigged AND Fucked"
                  value={both?.result}
                  loading={isLoading}
                />
              </div>
            )}
          </div>
        ) : null}
      </CardContent>
    </Card>
  );
}

function Stat({
  label,
  value,
  loading,
}: {
  label: string;
  value: bigint | undefined;
  loading: boolean;
}) {
  return (
    <div className="rounded-lg border border-border bg-muted/30 p-3 flex flex-col gap-1">
      <div className="text-xs uppercase tracking-wide text-muted-foreground">{label}</div>
      <div className="font-heading text-xl font-semibold tabular-nums">
        {loading || value === undefined ? (
          <Skeleton className="h-7 w-12" />
        ) : (
          numberFmt.format(value)
        )}
      </div>
    </div>
  );
}

function BoolStat({
  label,
  value,
  loading,
}: {
  label: string;
  value: boolean | undefined;
  loading: boolean;
}) {
  return (
    <div className="rounded-lg border border-border bg-muted/30 p-3 flex flex-col gap-1">
      <div className="text-xs uppercase tracking-wide text-muted-foreground">{label}</div>
      <div>
        {loading || value === undefined ? (
          <Skeleton className="h-7 w-16" />
        ) : value ? (
          <Badge className="bg-emerald-500/15 text-emerald-600 dark:text-emerald-400 hover:bg-emerald-500/15">
            yes
          </Badge>
        ) : (
          <Badge variant="secondary">no</Badge>
        )}
      </div>
    </div>
  );
}
