import { useQuery } from "@tanstack/react-query";

import {
  Card,
  CardHeader,
  CardTitle,
  CardDescription,
  CardContent,
} from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { KIM_JONG_UN_ADDRESS } from "@/lib/contract";

const numberFmt = new Intl.NumberFormat("en-US");

type StatsPayload = {
  totalVerifiedAddresses: bigint;
  totalPigCalls: bigint;
  totalFuckCalls: bigint;
  fetchedAt: number;
};

type StatTone = "neutral" | "pig" | "fuck";

async function fetchStats(): Promise<StatsPayload> {
  const res = await fetch("/api/stats", {
    headers: { accept: "application/json" },
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`stats endpoint responded ${res.status}: ${text.slice(0, 120)}`);
  }
  const raw = (await res.json()) as {
    totalVerifiedAddresses: string;
    totalPigCalls: string;
    totalFuckCalls: string;
    fetchedAt: number;
  };
  return {
    totalVerifiedAddresses: BigInt(raw.totalVerifiedAddresses),
    totalPigCalls: BigInt(raw.totalPigCalls),
    totalFuckCalls: BigInt(raw.totalFuckCalls),
    fetchedAt: raw.fetchedAt,
  };
}

const TONE_STYLES: Record<StatTone, { box: string; value: string }> = {
  neutral: {
    box: "border-border bg-muted/30",
    value: "text-foreground",
  },
  pig: {
    box: "border-pink-500/40 bg-pink-500/10",
    value: "text-pink-600 dark:text-pink-300",
  },
  fuck: {
    box: "border-red-500/40 bg-red-500/10",
    value: "text-red-600 dark:text-red-400",
  },
};

export function GlobalStats() {
  const { data, isLoading, error, refetch, isRefetching } = useQuery({
    queryKey: ["global-stats"],
    queryFn: fetchStats,
    refetchInterval: 15_000,
    staleTime: 10_000,
  });

  const stats: Array<{
    label: string;
    value: bigint | undefined;
    description: string;
    tone: StatTone;
  }> = [
    {
      label: "Non-DPRK Wallets",
      value: data?.totalVerifiedAddresses,
      description: "Unique addresses flagged isRegardedAsNotNorthKoreanHackerActor",
      tone: "neutral",
    },
    {
      label: "Total pig() calls",
      value: data?.totalPigCalls,
      description: "Across all addresses, all time",
      tone: "pig",
    },
    {
      label: "Total fuck() calls",
      value: data?.totalFuckCalls,
      description: "Across all addresses, all time",
      tone: "fuck",
    },
  ];

  return (
    <Card>
      <CardHeader>
        <CardTitle>Global stats</CardTitle>
        <CardDescription>
          Live counters from{" "}
          <a
            className="underline font-mono text-xs"
            target="_blank"
            rel="noreferrer"
            href={`https://etherscan.io/address/${KIM_JONG_UN_ADDRESS}`}
          >
            {KIM_JONG_UN_ADDRESS}
          </a>
          . Served from Netlify's durable edge cache (≤15s stale), so every visitor shares the
          same RPC hit.
          {isRefetching ? " · refreshing…" : null}
        </CardDescription>
      </CardHeader>
      <CardContent>
        {error ? (
          <div className="space-y-2">
            <p className="text-sm text-destructive">
              Stats endpoint unreachable: {error instanceof Error ? error.message : String(error)}
            </p>
            <button
              onClick={() => refetch()}
              className="text-xs underline text-muted-foreground"
            >
              Retry
            </button>
          </div>
        ) : (
          <>
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
              {stats.map((s) => {
                const tone = TONE_STYLES[s.tone];
                return (
                  <div
                    key={s.label}
                    className={`rounded-lg border p-4 flex flex-col gap-1 ${tone.box}`}
                  >
                    <div className="text-xs uppercase tracking-wide text-muted-foreground">
                      {s.label}
                    </div>
                    <div
                      className={`font-heading text-3xl font-semibold tabular-nums ${tone.value}`}
                    >
                      {isLoading || s.value === undefined ? (
                        <Skeleton className="h-9 w-20" />
                      ) : (
                        numberFmt.format(s.value)
                      )}
                    </div>
                    <div className="text-xs text-muted-foreground">{s.description}</div>
                  </div>
                );
              })}
            </div>
            <img
              src="/stats.webp"
              alt="Global verification stats"
              width={1200}
              height={238}
              loading="lazy"
              className="mt-4 w-full h-auto rounded-xl ring-1 ring-foreground/10 object-cover aspect-[1200/238]"
            />
          </>
        )}
      </CardContent>
    </Card>
  );
}
