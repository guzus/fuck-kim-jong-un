import { useMemo } from "react";
import { useInfiniteQuery } from "@tanstack/react-query";
import { readContract } from "wagmi/actions";

import { Link } from "@/components/link";
import { CurveProgress } from "@/components/launchpad/progress-bar";
import { TokenImage } from "@/components/launchpad/token-image";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { dprkLaunchpadAbi } from "@/lib/abi/launchpad";
import { launchpadConfig } from "@/lib/launchpad/config";
import { marketCapWei, progressBps, type TokenInfo } from "@/lib/launchpad/curve";
import { describeError } from "@/lib/launchpad/errors";
import { formatAmount, formatBps, shortAddress, timeAgo } from "@/lib/launchpad/format";
import { retryUnlessRevert, useLaunchpadConstants, useNowSeconds } from "@/lib/launchpad/hooks";
import { cleanLabel, parseTokenMetadata } from "@/lib/launchpad/metadata";
import { routes } from "@/lib/router";
import { wagmiConfig } from "@/lib/wagmi";

const PAGE_SIZE = 12;
const chainId = launchpadConfig.chainId;
const symbolUnit = launchpadConfig.nativeSymbol;

type Page = { offset: number; count: bigint; infos: readonly TokenInfo[] };

/**
 * One page of getTokenInfos (newest first). tokenCount is read alongside it so the grid knows when to
 * stop, and an offset past the end never calls getTokenInfos at all.
 */
async function fetchPage(launchpad: `0x${string}`, offset: number): Promise<Page> {
  const [count, infos] = await Promise.allSettled([
    readContract(wagmiConfig, { address: launchpad, abi: dprkLaunchpadAbi, functionName: "tokenCount", chainId }),
    readContract(wagmiConfig, {
      address: launchpad,
      abi: dprkLaunchpadAbi,
      functionName: "getTokenInfos",
      args: [BigInt(offset), BigInt(PAGE_SIZE)],
      chainId,
    }),
  ]);
  if (count.status === "rejected") throw count.reason;
  if (count.value <= BigInt(offset)) return { offset, count: count.value, infos: [] };
  if (infos.status === "rejected") throw infos.reason;
  return { offset, count: count.value, infos: infos.value };
}

function useTokenList() {
  const launchpad = launchpadConfig.addresses.launchpad;
  return useInfiniteQuery({
    queryKey: ["dprk-launchpad", chainId, launchpad, "token-list"],
    queryFn: ({ pageParam }) => fetchPage(launchpad!, pageParam),
    initialPageParam: 0,
    getNextPageParam: (last) => {
      const next = last.offset + last.infos.length;
      return last.infos.length === PAGE_SIZE && BigInt(next) < last.count ? next : undefined;
    },
    enabled: launchpadConfig.isDeployed,
    refetchInterval: 20_000,
    retry: retryUnlessRevert,
  });
}

function TokenCard({
  info,
  totalSupply,
  curveSupply,
  now,
}: {
  info: TokenInfo;
  totalSupply: bigint | undefined;
  curveSupply: bigint | undefined;
  now: number;
}) {
  const meta = useMemo(() => parseTokenMetadata(info.metadata), [info.metadata]);
  const name = cleanLabel(info.name, 64);
  const symbol = cleanLabel(info.symbol, 16, "???");
  const mcap = totalSupply === undefined ? undefined : marketCapWei(info.state, totalSupply);
  const progress = curveSupply === undefined ? undefined : progressBps(info.state, curveSupply);

  return (
    <Link
      href={routes.token(info.token)}
      className="group flex min-w-0 flex-col gap-3 rounded-xl bg-card p-4 ring-1 ring-foreground/10 transition-shadow hover:shadow-md hover:ring-foreground/20"
    >
      <div className="flex min-w-0 items-start gap-3">
        <TokenImage src={meta.image} symbol={symbol} seed={info.token} className="size-14 text-xl" />
        <div className="flex min-w-0 flex-1 flex-col gap-0.5">
          <div className="flex min-w-0 items-center gap-2">
            <bdi className="truncate font-heading font-semibold">{name}</bdi>
            {info.state.graduated ? (
              <Badge className="shrink-0 bg-blue-600 text-white">Graduated</Badge>
            ) : null}
          </div>
          <bdi className="truncate font-mono text-xs text-muted-foreground">${symbol}</bdi>
          <span className="text-xs text-muted-foreground">
            {timeAgo(info.state.createdAt, now * 1000)} · by {shortAddress(info.state.creator)}
          </span>
        </div>
      </div>
      {meta.description ? (
        <p className="line-clamp-2 min-h-8 text-xs text-muted-foreground [overflow-wrap:anywhere]">
          {meta.description}
        </p>
      ) : (
        <p className="min-h-8 text-xs italic text-muted-foreground/70">No description.</p>
      )}
      <div className="mt-auto flex flex-col gap-1.5">
        <CurveProgress bps={progress ?? 0} graduated={info.state.graduated} />
        <div className="flex items-center justify-between text-xs">
          <span className="text-muted-foreground">
            {info.state.graduated ? "On PancakeSwap" : progress === undefined ? "…" : `${formatBps(progress)} sold`}
          </span>
          <span className="font-medium tabular-nums">
            MC {mcap === undefined ? "…" : `${formatAmount(mcap)} ${symbolUnit}`}
          </span>
        </div>
      </div>
    </Link>
  );
}

export function TokenGrid() {
  const query = useTokenList();
  const { constants } = useLaunchpadConstants();
  const now = useNowSeconds();

  const tokens = useMemo(() => {
    // Offsets shift when a token is created between page loads, so a token can appear on two pages.
    const seen = new Set<string>();
    const out: TokenInfo[] = [];
    for (const page of query.data?.pages ?? []) {
      for (const info of page.infos) {
        const key = info.token.toLowerCase();
        if (seen.has(key)) continue;
        seen.add(key);
        out.push(info);
      }
    }
    return out;
  }, [query.data]);

  if (query.isLoading) {
    return (
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {Array.from({ length: 3 }, (_, i) => (
          <Skeleton key={i} className="h-44 rounded-xl" />
        ))}
      </div>
    );
  }

  if (query.error && tokens.length === 0) {
    return (
      <div className="flex flex-col items-start gap-2 rounded-xl border border-dashed border-border p-6 text-sm">
        <p className="text-destructive">Couldn&apos;t load tokens: {describeError(query.error)}</p>
        <Button variant="outline" size="sm" onClick={() => query.refetch()}>
          Retry
        </Button>
      </div>
    );
  }

  if (tokens.length === 0) {
    return (
      <div className="flex flex-col items-start gap-3 rounded-xl border border-dashed border-border p-6">
        <p className="font-heading text-lg font-semibold">No tokens yet.</p>
        <p className="text-sm text-muted-foreground">
          The curve is empty and Lazarus is locked out. Be the first certified degen to launch one.
        </p>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {tokens.map((info) => (
          <TokenCard
            key={info.token}
            info={info}
            totalSupply={constants?.totalSupply}
            curveSupply={constants?.curveSupply}
            now={now}
          />
        ))}
      </div>
      {query.hasNextPage ? (
        <Button
          variant="outline"
          className="self-center"
          disabled={query.isFetchingNextPage}
          onClick={() => query.fetchNextPage()}
        >
          {query.isFetchingNextPage ? "Loading…" : "Load more"}
        </Button>
      ) : null}
    </div>
  );
}
