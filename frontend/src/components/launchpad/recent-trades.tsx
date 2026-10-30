import { useQuery } from "@tanstack/react-query";
import { ExternalLink } from "lucide-react";
import type { Address, Hash } from "viem";
import { getPublicClient } from "wagmi/actions";

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { dprkLaunchpadAbi } from "@/lib/abi/launchpad";
import { explorerUrl, launchpadConfig } from "@/lib/launchpad/config";
import { formatAmount, shortAddress, timeAgo } from "@/lib/launchpad/format";
import { useNowSeconds } from "@/lib/launchpad/hooks";
import { wagmiConfig } from "@/lib/wagmi";
import { cn } from "@/lib/utils";

const chainId = launchpadConfig.chainId;
const unit = launchpadConfig.nativeSymbol;

// Public BSC RPCs cap eth_getLogs ranges (often a few thousand blocks) or refuse it outright, and BSC
// makes a block every ~0.75 s. So: walk backwards from the head in chunks, shrink the chunk when the RPC
// complains, stop after a fixed number of requests, and never go below VITE_DPRK_DEPLOY_BLOCK.
const INITIAL_SPAN = 5_000n;
const MIN_SPAN = 500n;
const MAX_REQUESTS = 8;
const MAX_ROWS = 25;
/** Without a deploy block, look back at most this far on a public chain. */
const DEFAULT_LOOKBACK = 50_000n;

type TradeRow = {
  key: string;
  isBuy: boolean;
  trader: Address;
  bnbAmount: bigint;
  tokenAmount: bigint;
  blockNumber: bigint;
  timestamp?: bigint;
  txHash: Hash;
};

type TradeScan = { rows: TradeRow[]; head: bigint; reachedFloor: boolean; scannedFrom: bigint; note?: string };

async function scanTrades(token: Address): Promise<TradeScan> {
  const launchpad = launchpadConfig.addresses.launchpad!;
  const client = getPublicClient(wagmiConfig, { chainId });
  if (!client) throw new Error("No client for the launchpad chain");
  // cacheTime 0: right after the user's own trade the cached head would still predate it.
  const head = await client.getBlockNumber({ cacheTime: 0 });
  const floor =
    launchpadConfig.deployBlock ??
    (chainId === 31337 ? 0n : head > DEFAULT_LOOKBACK ? head - DEFAULT_LOOKBACK : 0n);

  // Local anvil answers any range in one go.
  let span = chainId === 31337 ? head - floor + 1n : INITIAL_SPAN;
  let to = head;
  let requests = 0;
  let note: string | undefined;
  const rows: TradeRow[] = [];

  while (to >= floor && requests < MAX_REQUESTS && rows.length < MAX_ROWS) {
    const from = to - span + 1n > floor ? to - span + 1n : floor;
    requests += 1;
    try {
      const logs = await client.getContractEvents({
        address: launchpad,
        abi: dprkLaunchpadAbi,
        eventName: "Trade",
        args: { token },
        fromBlock: from,
        toBlock: to,
      });
      for (const log of logs) {
        if (log.blockNumber === null || log.transactionHash === null) continue;
        rows.push({
          key: `${log.transactionHash}-${log.logIndex}`,
          isBuy: log.args.isBuy ?? false,
          trader: log.args.trader!,
          bnbAmount: log.args.bnbAmount ?? 0n,
          tokenAmount: log.args.tokenAmount ?? 0n,
          blockNumber: log.blockNumber,
          timestamp: typeof log.blockTimestamp === "bigint" ? log.blockTimestamp : undefined,
          txHash: log.transactionHash,
        });
      }
      to = from - 1n;
    } catch {
      if (span > MIN_SPAN) {
        span = span / 4n > MIN_SPAN ? span / 4n : MIN_SPAN;
        continue;
      }
      note = "This RPC refused the log query, so older trades are missing.";
      break;
    }
  }

  rows.sort((a, b) => (a.blockNumber === b.blockNumber ? b.key.localeCompare(a.key) : a.blockNumber > b.blockNumber ? -1 : 1));
  return { rows: rows.slice(0, MAX_ROWS), head, reachedFloor: to < floor, scannedFrom: to + 1n, note };
}

function age(row: TradeRow, head: bigint | undefined, now: number): string {
  if (row.timestamp !== undefined) return timeAgo(row.timestamp, now * 1000);
  const blockTime = launchpadConfig.chain.blockTime;
  if (head !== undefined && blockTime && chainId !== 31337) {
    const seconds = (Number(head - row.blockNumber) * blockTime) / 1000;
    return `~${timeAgo(now - seconds, now * 1000)}`;
  }
  return `#${row.blockNumber.toString()}`;
}

export function RecentTrades({ token, symbol }: { token: Address; symbol: string }) {
  const now = useNowSeconds();
  const query = useQuery({
    queryKey: ["dprk-launchpad", chainId, launchpadConfig.addresses.launchpad, "trades", token],
    queryFn: () => scanTrades(token),
    refetchInterval: 45_000,
    staleTime: 15_000,
    retry: false,
  });

  const rows = query.data?.rows ?? [];

  return (
    <Card>
      <CardHeader>
        <CardTitle>Recent trades</CardTitle>
        <CardDescription>
          Best effort, straight from on-chain Trade logs.
          {query.data && !query.data.reachedFloor && rows.length < MAX_ROWS
            ? ` Searched back to block ${query.data.scannedFrom.toString()}.`
            : ""}
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-2">
        {query.isLoading ? (
          <Skeleton className="h-24" />
        ) : query.error ? (
          <p className="text-sm text-muted-foreground">
            Trade history isn&apos;t available from this RPC right now. Trading still works.
          </p>
        ) : rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">No trades found yet.</p>
        ) : (
          <ul className="flex flex-col divide-y divide-border text-xs" data-testid="recent-trades">
            {rows.map((row) => {
              const href = explorerUrl("tx", row.txHash);
              return (
                <li key={row.key} className="grid grid-cols-[3rem_minmax(0,1fr)_auto] items-center gap-2 py-2 sm:grid-cols-[3rem_7rem_minmax(0,1fr)_auto]">
                  <span
                    className={cn(
                      "font-medium",
                      row.isBuy ? "text-emerald-600 dark:text-emerald-400" : "text-red-600 dark:text-red-400",
                    )}
                  >
                    {row.isBuy ? "Buy" : "Sell"}
                  </span>
                  <span className="hidden font-mono text-muted-foreground sm:inline">{shortAddress(row.trader)}</span>
                  <span className="truncate tabular-nums">
                    {formatAmount(row.bnbAmount)} {unit} · {formatAmount(row.tokenAmount)} {symbol}
                  </span>
                  <span className="flex items-center gap-1 text-muted-foreground">
                    {age(row, query.data?.head, now)}
                    {href ? (
                      <a href={href} target="_blank" rel="noopener noreferrer" aria-label="View transaction">
                        <ExternalLink className="size-3" />
                      </a>
                    ) : null}
                  </span>
                </li>
              );
            })}
          </ul>
        )}
        {query.data?.note ? <p className="text-xs text-muted-foreground">{query.data.note}</p> : null}
      </CardContent>
    </Card>
  );
}
