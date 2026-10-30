import { useMemo, type ReactNode } from "react";
import { ArrowLeft, Copy, ExternalLink } from "lucide-react";
import { toast } from "sonner";
import { getAddress, isAddress, zeroAddress, type Address } from "viem";
import { useBalance, useReadContract } from "wagmi";

import { Link } from "@/components/link";
import { MetadataLinks } from "@/components/launchpad/external-links";
import { LaunchpadShell } from "@/components/launchpad/launchpad-shell";
import { CurveProgress } from "@/components/launchpad/progress-bar";
import { RecentTrades } from "@/components/launchpad/recent-trades";
import { TokenImage } from "@/components/launchpad/token-image";
import { TradePanel } from "@/components/launchpad/trade-panel";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Skeleton } from "@/components/ui/skeleton";
import { dprkLaunchpadAbi, dprkTokenAbi } from "@/lib/abi/launchpad";
import { explorerUrl, launchpadConfig, pancakeSwapUrl } from "@/lib/launchpad/config";
import { marketCapWei, progressBps, spotPriceE18, type TokenInfo } from "@/lib/launchpad/curve";
import { describeError, revertName } from "@/lib/launchpad/errors";
import { formatAmount, formatBps, shortAddress, timeAgo } from "@/lib/launchpad/format";
import { useLaunchpadConstants, useLaunchpadWallet, useNowSeconds } from "@/lib/launchpad/hooks";
import { cleanLabel, parseTokenMetadata } from "@/lib/launchpad/metadata";
import { routes } from "@/lib/router";
import { useDocumentTitle } from "@/lib/use-document-title";

const chainId = launchpadConfig.chainId;
const unit = launchpadConfig.nativeSymbol;

function BackLink() {
  return (
    <Link
      href={routes.launchpad}
      className="inline-flex w-fit items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
    >
      <ArrowLeft className="size-3.5" /> All tokens
    </Link>
  );
}

function Stat({ label, value, sub }: { label: string; value: ReactNode; sub?: ReactNode }) {
  return (
    <div className="flex min-w-0 flex-col gap-1 rounded-lg border border-border bg-muted/30 p-3">
      <span className="text-[11px] uppercase tracking-wide text-muted-foreground">{label}</span>
      <span className="truncate font-heading text-lg font-semibold tabular-nums">{value}</span>
      {sub ? <span className="truncate text-xs text-muted-foreground">{sub}</span> : null}
    </div>
  );
}

function AddressLine({ label, address }: { label: string; address: Address }) {
  const href = explorerUrl("address", address);
  return (
    <span className="inline-flex items-center gap-1.5">
      <span className="text-muted-foreground">{label}</span>
      <span className="font-mono">{shortAddress(address)}</span>
      <button
        type="button"
        aria-label={`Copy ${label.toLowerCase()} address`}
        className="text-muted-foreground hover:text-foreground"
        onClick={() => {
          void navigator.clipboard?.writeText(address).then(
            () => toast.success("Address copied"),
            () => toast.error("Couldn't copy"),
          );
        }}
      >
        <Copy className="size-3" />
      </button>
      {href ? (
        <a
          href={href}
          target="_blank"
          rel="noopener noreferrer"
          aria-label={`${label} on explorer`}
          className="text-muted-foreground hover:text-foreground"
        >
          <ExternalLink className="size-3" />
        </a>
      ) : null}
    </span>
  );
}

function WalletBalances({ token, symbol, priceE18 }: { token: Address; symbol: string; priceE18?: bigint }) {
  const { account } = useLaunchpadWallet();
  const bnb = useBalance({ address: account, chainId, query: { enabled: Boolean(account), refetchInterval: 15_000 } });
  const held = useReadContract({
    address: token,
    abi: dprkTokenAbi,
    functionName: "balanceOf",
    args: [account ?? zeroAddress],
    chainId,
    query: { enabled: Boolean(account), refetchInterval: 15_000 },
  });
  if (!account) return null;
  const valueWei = held.data !== undefined && priceE18 !== undefined ? (held.data * priceE18) / 10n ** 18n : undefined;
  return (
    <Card size="sm" data-testid="wallet-balances">
      <CardContent className="flex flex-col gap-1.5 text-sm">
        <span className="text-[11px] uppercase tracking-wide text-muted-foreground">Your wallet</span>
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-muted-foreground">{symbol}</span>
          <span className="font-medium tabular-nums">
            {held.data === undefined ? "…" : formatAmount(held.data)}
            {valueWei !== undefined && valueWei > 0n ? (
              <span className="ml-1 text-xs font-normal text-muted-foreground">
                ≈ {formatAmount(valueWei)} {unit}
              </span>
            ) : null}
          </span>
        </div>
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-muted-foreground">{unit}</span>
          <span className="font-medium tabular-nums">{bnb.data ? formatAmount(bnb.data.value) : "…"}</span>
        </div>
      </CardContent>
    </Card>
  );
}

function TokenView({ info }: { info: TokenInfo }) {
  const { constants } = useLaunchpadConstants();
  const now = useNowSeconds();
  const meta = useMemo(() => parseTokenMetadata(info.metadata), [info.metadata]);
  const name = cleanLabel(info.name, 64);
  const symbol = cleanLabel(info.symbol, 16, "???");

  const { state } = info;
  const price = spotPriceE18(state);
  const mcap = constants ? marketCapWei(state, constants.totalSupply) : undefined;
  const progress = constants ? progressBps(state, constants.curveSupply) : undefined;
  const raised = state.graduated && constants ? constants.graduationBnb : state.realBnbReserve;
  const swap = pancakeSwapUrl(info.token);

  return (
    // Three grid items so that on mobile the trade panel comes right after the stats, while on desktop
    // it sits in a sticky right column next to both.
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_22rem]">
      <div className="flex min-w-0 flex-col gap-6 lg:col-start-1 lg:row-start-1">
        <section className="flex min-w-0 flex-col gap-4">
          <div className="flex min-w-0 items-start gap-4">
            <TokenImage src={meta.image} symbol={symbol} seed={info.token} className="size-20 text-3xl" />
            <div className="flex min-w-0 flex-1 flex-col gap-1">
              <div className="flex min-w-0 flex-wrap items-center gap-2">
                <h1 className="line-clamp-2 min-w-0 font-heading text-2xl font-bold tracking-tight [overflow-wrap:anywhere] sm:text-3xl">
                  <bdi>{name}</bdi>
                </h1>
                {state.graduated ? (
                  <Badge className="bg-blue-600 text-white">Graduated</Badge>
                ) : (
                  <Badge variant="secondary">Bonding curve</Badge>
                )}
              </div>
              <bdi className="truncate font-mono text-sm text-muted-foreground">${symbol}</bdi>
              <div className="flex flex-wrap gap-x-4 gap-y-1 text-xs">
                <AddressLine label="Token" address={info.token} />
                <AddressLine label="Creator" address={state.creator} />
                <span className="text-muted-foreground">created {timeAgo(state.createdAt, now * 1000)}</span>
              </div>
            </div>
          </div>
          <MetadataLinks metadata={meta} />
          {meta.description ? (
            <p className="max-h-48 overflow-y-auto whitespace-pre-line rounded-lg bg-muted/30 p-3 text-sm text-muted-foreground [overflow-wrap:anywhere]">
              {meta.description}
            </p>
          ) : null}
        </section>

        <section className="flex flex-col gap-3">
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            {/* After graduation the curve's reserves are frozen: they price the PancakeSwap listing, not today. */}
            <Stat
              label={state.graduated ? "Listing price" : "Price"}
              value={price === undefined ? "—" : `${formatAmount(price)}`}
              sub={`${unit} per ${symbol}`}
            />
            <Stat
              label="Market cap"
              value={mcap === undefined ? "…" : `${formatAmount(mcap)} ${unit}`}
              sub={state.graduated ? "at listing" : "fully diluted"}
            />
            <Stat
              label="Raised"
              value={`${formatAmount(raised)} ${unit}`}
              sub={constants ? `of ${formatAmount(constants.graduationBnb)} ${unit}` : undefined}
            />
            <Stat
              label="Curve sold"
              value={progress === undefined ? "…" : formatBps(progress)}
              sub={state.graduated ? "on PancakeSwap" : "of the curve supply"}
            />
          </div>
          <CurveProgress bps={progress ?? 0} graduated={state.graduated} className="h-3" />
          {state.graduated ? (
            <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs">
              {state.pair !== zeroAddress ? <AddressLine label="PancakeSwap pair" address={state.pair} /> : null}
              {swap ? (
                <a
                  href={swap}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1 font-medium text-blue-600 underline-offset-4 hover:underline dark:text-blue-400"
                >
                  Trade on PancakeSwap <ExternalLink className="size-3" />
                </a>
              ) : null}
            </div>
          ) : null}
        </section>
      </div>

      <aside className="flex flex-col gap-4 lg:sticky lg:top-6 lg:col-start-2 lg:row-span-2 lg:row-start-1 lg:self-start">
        <TradePanel info={info} symbol={symbol} feeBps={constants?.feeBps} />
        <WalletBalances token={info.token} symbol={symbol} priceE18={state.graduated ? undefined : price} />
      </aside>

      <div className="min-w-0 lg:col-start-1 lg:row-start-2">
        <RecentTrades token={info.token} symbol={symbol} />
      </div>
    </div>
  );
}

function TokenLoader({ token }: { token: Address }) {
  const launchpad = launchpadConfig.addresses.launchpad!;
  const query = useReadContract({
    address: launchpad,
    abi: dprkLaunchpadAbi,
    functionName: "getTokenInfo",
    args: [token],
    chainId,
    query: {
      refetchInterval: 10_000,
      // Retry reverts too, briefly: right after createToken a load-balanced RPC can still be a block behind.
      retry: 2,
      retryDelay: 1_500,
    },
  });

  // One owner for the title (a child's effect runs before its parent's, so two would race).
  useDocumentTitle(
    query.data
      ? `$${cleanLabel(query.data.symbol, 16, "???")} · ${cleanLabel(query.data.name, 64)} · DPRK.FUN`
      : `${shortAddress(token)} · DPRK.FUN`,
  );

  if (query.isLoading) {
    return (
      <div className="flex flex-col gap-4">
        <Skeleton className="h-20 w-full max-w-md" />
        <Skeleton className="h-24 w-full" />
      </div>
    );
  }
  if (query.error || !query.data) {
    const unknown = revertName(query.error) === "UnknownToken";
    return (
      <Card>
        <CardHeader>
          <CardTitle>{unknown ? "Not a DPRK.FUN token" : "Couldn't load this token"}</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-2 text-sm text-muted-foreground">
          <p>
            {unknown
              ? `${shortAddress(token)} wasn't launched through this launchpad. Only tokens created here have a curve.`
              : describeError(query.error)}
          </p>
          {!unknown ? (
            <button type="button" className="w-fit underline underline-offset-4" onClick={() => query.refetch()}>
              Retry
            </button>
          ) : null}
        </CardContent>
      </Card>
    );
  }
  return <TokenView info={query.data} />;
}

export default function TokenPage({ rawAddress }: { rawAddress: string }) {
  const token = isAddress(rawAddress, { strict: false }) ? getAddress(rawAddress) : undefined;
  // Valid addresses get their title from TokenView once the token loads.
  useDocumentTitle(token ? undefined : "Not found · DPRK.FUN");
  return (
    <LaunchpadShell hero={<BackLink />}>
      {token ? (
        <TokenLoader token={token} />
      ) : (
        <Card>
          <CardHeader>
            <CardTitle>That isn&apos;t a token address</CardTitle>
          </CardHeader>
          <CardContent className="text-sm text-muted-foreground">
            Token pages live at /launchpad/token/0x… with a 40-hex-character address.
          </CardContent>
        </Card>
      )}
    </LaunchpadShell>
  );
}
