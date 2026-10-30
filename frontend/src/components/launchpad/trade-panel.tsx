import { useState } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { ExternalLink, Lock } from "lucide-react";
import { toast } from "sonner";
import { isAddressEqual, parseEventLogs, zeroAddress, type Address, type TransactionReceipt } from "viem";
import { useBalance, useGasPrice, useReadContract } from "wagmi";
import { readContract, simulateContract, writeContract } from "wagmi/actions";

import { Link } from "@/components/link";
import { TradeSettings } from "@/components/launchpad/trade-settings";
import { WalletGate } from "@/components/launchpad/wallet-gate";
import { Button, buttonVariants } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { dprkLaunchpadAbi, dprkTokenAbi } from "@/lib/abi/launchpad";
import { explorerUrl, launchpadConfig, pancakeSwapUrl } from "@/lib/launchpad/config";
import { applySlippage, mayCompleteCurve, type TokenInfo } from "@/lib/launchpad/curve";
import { describeError } from "@/lib/launchpad/errors";
import { formatAmount, formatBps, parseAmountInput, toInputString } from "@/lib/launchpad/format";
import { retryUnlessRevert, useDebounced, useLaunchpadWallet, useTradeGate } from "@/lib/launchpad/hooks";
import { routes } from "@/lib/router";
import {
  DEFAULT_DEADLINE_MINUTES,
  DEFAULT_SLIPPAGE_BPS,
  GRADUATING_BUY_GAS,
  PriceMovedError,
  submitDeadline,
  TxRevertedError,
  waitForSuccess,
} from "@/lib/launchpad/tx";
import { wagmiConfig } from "@/lib/wagmi";
import { cn } from "@/lib/utils";

const chainId = launchpadConfig.chainId;
const unit = launchpadConfig.nativeSymbol;

const BUY_PRESETS: Record<number, string[]> = {
  56: ["0.05", "0.1", "0.5", "1"],
  97: ["0.01", "0.05", "0.1", "0.5"],
  31337: ["0.1", "0.5", "1", "2"],
};

type Side = "buy" | "sell";

function graduatedIn(receipt: TransactionReceipt, launchpad: Address, token: Address): boolean {
  return parseEventLogs({ abi: dprkLaunchpadAbi, eventName: "Graduated", logs: receipt.logs }).some(
    (log) => isAddressEqual(log.address, launchpad) && isAddressEqual(log.args.token, token),
  );
}

/**
 * Buy/sell against one curve. Displayed quotes are for reading only: every submit re-quotes, derives
 * min-out from that fresh quote, sets the deadline, simulates, and only then asks the wallet to sign.
 */
export function TradePanel({
  info,
  symbol,
  feeBps,
}: {
  info: TokenInfo;
  symbol: string;
  feeBps: number | undefined;
}) {
  const token = info.token;
  const graduated = info.state.graduated;
  const launchpad = launchpadConfig.addresses.launchpad!;

  const [side, setSide] = useState<Side>("buy");
  const [amountText, setAmountText] = useState("");
  const [slippageBps, setSlippageBps] = useState(DEFAULT_SLIPPAGE_BPS);
  const [deadlineMinutes, setDeadlineMinutes] = useState(DEFAULT_DEADLINE_MINUTES);
  const [busy, setBusy] = useState<string | null>(null);
  const [lastError, setLastError] = useState<string | null>(null);

  const queryClient = useQueryClient();
  const { account, connected, wrongChain } = useLaunchpadWallet();
  const gate = useTradeGate(account);

  const bnbBalance = useBalance({
    address: account,
    chainId,
    query: { enabled: Boolean(account), refetchInterval: 15_000 },
  });
  const tokenBalance = useReadContract({
    address: token,
    abi: dprkTokenAbi,
    functionName: "balanceOf",
    args: [account ?? zeroAddress],
    chainId,
    query: { enabled: Boolean(account), refetchInterval: 15_000 },
  });

  const parsed = parseAmountInput(amountText);
  const amount = parsed.status === "ok" ? parsed.value : 0n;
  const debounced = useDebounced(amount);

  const buyQuote = useReadContract({
    address: launchpad,
    abi: dprkLaunchpadAbi,
    functionName: "quoteBuy",
    args: [token, debounced],
    chainId,
    query: {
      enabled: side === "buy" && debounced > 0n && !graduated,
      refetchInterval: 10_000,
      retry: retryUnlessRevert,
    },
  });
  const sellQuote = useReadContract({
    address: launchpad,
    abi: dprkLaunchpadAbi,
    functionName: "quoteSell",
    args: [token, debounced],
    chainId,
    query: {
      enabled: side === "sell" && debounced > 0n && !graduated,
      refetchInterval: 10_000,
      retry: retryUnlessRevert,
    },
  });
  const activeQuote = side === "buy" ? buyQuote : sellQuote;
  const quoteIsCurrent = debounced === amount && activeQuote.data !== undefined && !activeQuote.isError;

  const [buyTokensOut, buyFee, buyAccepted, buyRefund] = side === "buy" && quoteIsCurrent ? (buyQuote.data ?? []) : [];
  const [sellBnbOut, sellFee] = side === "sell" && quoteIsCurrent ? (sellQuote.data ?? []) : [];
  const quotedOut = side === "buy" ? buyTokensOut : sellBnbOut;

  // A buy that may finish the curve goes out with GRADUATING_BUY_GAS (see onBuy), and the wallet wants
  // value + limit × gas price up front, so count that here and explain it instead of the wallet's error.
  const gasPrice = useGasPrice({ chainId, query: { enabled: side === "buy" && !graduated, refetchInterval: 30_000 } });
  const gasReserve =
    buyTokensOut !== undefined &&
    gasPrice.data !== undefined &&
    mayCompleteCurve(info.state, (buyAccepted ?? 0n) - (buyFee ?? 0n), applySlippage(buyTokensOut, slippageBps))
      ? GRADUATING_BUY_GAS * gasPrice.data
      : 0n;

  const switchSide = (next: Side) => {
    setSide(next);
    setAmountText("");
    setLastError(null);
  };

  // ------------------------------------------------------------------ blockers
  // `label` goes on the (disabled) button, so it stays short; `detail` explains underneath.
  let blocker: { label: string; detail?: string } | undefined;
  if (graduated) blocker = { label: "Graduated" };
  else if (side === "buy" && gate.canTrade === false) blocker = { label: "Pass holders only" };
  else if (side === "buy" && gate.paused)
    blocker = { label: "Buying paused", detail: "The owner paused the launchpad. Selling still works." };
  else if (parsed.status === "invalid") blocker = { label: "Invalid amount", detail: parsed.message };
  else if (amount === 0n) blocker = { label: "Enter an amount" };
  else if (side === "buy" && bnbBalance.data && amount + gasReserve > bnbBalance.data.value)
    blocker = {
      label: `Not enough ${unit}`,
      detail:
        gasReserve > 0n
          ? `This buy may finish the curve, so it goes out with a higher gas limit: keep up to ${formatAmount(gasReserve)} ${unit} on top for gas.`
          : undefined,
    };
  else if (side === "sell" && tokenBalance.data !== undefined && amount > tokenBalance.data)
    blocker = { label: `Not enough ${symbol}` };
  else if (activeQuote.isError) blocker = { label: "No quote", detail: describeError(activeQuote.error) };
  else if (!quoteIsCurrent) blocker = { label: "Fetching quote…" };
  else if (quotedOut === 0n) blocker = { label: "Amount too small" };

  // ------------------------------------------------------------------ actions
  async function onBuy(account: Address) {
    setBusy("Refreshing quote…");
    const [fresh, freshFee, freshAccepted] = await readContract(wagmiConfig, {
      address: launchpad,
      abi: dprkLaunchpadAbi,
      functionName: "quoteBuy",
      args: [token, amount],
      chainId,
    });
    if (buyTokensOut !== undefined && fresh < applySlippage(buyTokensOut, slippageBps)) {
      // Refresh the quote and the curve stats so the page shows the price the user is now facing.
      await queryClient.invalidateQueries();
      throw new PriceMovedError();
    }
    const minTokensOut = applySlippage(fresh, slippageBps);
    const deadline = await submitDeadline(deadlineMinutes);
    // A buy that finishes the curve also creates the PancakeSwap pair, and the wallet's estimate can come
    // from a block where it doesn't (another buy can land first), so set the limit whenever it might.
    const gas = mayCompleteCurve(info.state, freshAccepted - freshFee, minTokensOut) ? GRADUATING_BUY_GAS : undefined;

    setBusy("Simulating…");
    const { request } = await simulateContract(wagmiConfig, {
      address: launchpad,
      abi: dprkLaunchpadAbi,
      functionName: "buy",
      args: [token, minTokensOut, deadline],
      value: amount,
      gas,
      chainId,
      account,
    });
    setBusy("Confirm in wallet…");
    const hash = await writeContract(wagmiConfig, request);
    setBusy("Waiting for confirmation…");
    const receipt = await waitForSuccess(hash);
    return { hash, receipt };
  }

  async function onSell(account: Address) {
    // Allowance is read fresh: the cached value could predate another tab's approval or spend.
    setBusy("Checking allowance…");
    const allowance = await readContract(wagmiConfig, {
      address: token,
      abi: dprkTokenAbi,
      functionName: "allowance",
      args: [account, launchpad],
      chainId,
    });
    if (allowance < amount) {
      setBusy("Simulating approval…");
      const approval = await simulateContract(wagmiConfig, {
        address: token,
        abi: dprkTokenAbi,
        functionName: "approve",
        args: [launchpad, amount],
        chainId,
        account,
      });
      setBusy("Approve in wallet…");
      const approveHash = await writeContract(wagmiConfig, approval.request);
      setBusy("Waiting for approval…");
      await waitForSuccess(approveHash);
    }

    // The approval took at least a block; the quote on screen may be stale by now.
    setBusy("Refreshing quote…");
    const [fresh] = await readContract(wagmiConfig, {
      address: launchpad,
      abi: dprkLaunchpadAbi,
      functionName: "quoteSell",
      args: [token, amount],
      chainId,
    });
    if (sellBnbOut !== undefined && fresh < applySlippage(sellBnbOut, slippageBps)) {
      // Refresh the quote and the curve stats so the page shows the price the user is now facing.
      await queryClient.invalidateQueries();
      throw new PriceMovedError();
    }
    const minBnbOut = applySlippage(fresh, slippageBps);
    const deadline = await submitDeadline(deadlineMinutes);

    setBusy("Simulating…");
    const { request } = await simulateContract(wagmiConfig, {
      address: launchpad,
      abi: dprkLaunchpadAbi,
      functionName: "sell",
      args: [token, amount, minBnbOut, deadline],
      chainId,
      account,
    });
    setBusy("Confirm in wallet…");
    const hash = await writeContract(wagmiConfig, request);
    setBusy("Waiting for confirmation…");
    const receipt = await waitForSuccess(hash);
    return { hash, receipt };
  }

  async function submit() {
    if (!account || blocker || busy) return;
    setLastError(null);
    try {
      const { hash, receipt } = side === "buy" ? await onBuy(account) : await onSell(account);
      const link = explorerUrl("tx", hash);
      toast.success(side === "buy" ? `Bought $${symbol}` : `Sold $${symbol}`, {
        description: `${hash.slice(0, 10)}…${hash.slice(-8)}`,
        action: link ? { label: "View", onClick: () => window.open(link, "_blank", "noopener,noreferrer") } : undefined,
      });
      if (side === "buy" && graduatedIn(receipt, launchpad, token)) {
        toast.success(`$${symbol} graduated to PancakeSwap 🎓`, {
          description: "Your buy finished the curve and seeded the pool. The LP is burned.",
        });
      }
      setAmountText("");
      void queryClient.invalidateQueries();
    } catch (error) {
      const message = error instanceof PriceMovedError ? error.message : describeError(error);
      setLastError(message);
      toast.error(message);
      // A mined revert still changed things (gas spent, and usually someone else's trade moved the curve).
      if (error instanceof TxRevertedError) void queryClient.invalidateQueries();
    } finally {
      setBusy(null);
    }
  }

  // ------------------------------------------------------------------ render
  if (graduated) {
    const swap = pancakeSwapUrl(token);
    return (
      <Card>
        <CardContent className="flex flex-col gap-3">
          <span className="text-[11px] font-semibold uppercase tracking-widest text-blue-600 dark:text-blue-400">
            Graduated
          </span>
          <p className="text-sm text-muted-foreground">
            The curve sold out and seeded a PancakeSwap V2 pool in the same transaction. The LP
            tokens were burned, so the liquidity can&apos;t be pulled. Curve trading is closed.
          </p>
          {swap ? (
            <a
              href={swap}
              target="_blank"
              rel="noopener noreferrer"
              className={cn(buttonVariants({ size: "lg" }), "w-full")}
            >
              Trade on PancakeSwap <ExternalLink />
            </a>
          ) : (
            <p className="text-xs text-muted-foreground">No PancakeSwap UI for this network.</p>
          )}
        </CardContent>
      </Card>
    );
  }

  const presets = side === "buy" ? (BUY_PRESETS[chainId] ?? BUY_PRESETS[56]) : ["25", "50", "75", "100"];
  const balanceLine =
    side === "buy"
      ? bnbBalance.data
        ? `${formatAmount(bnbBalance.data.value)} ${unit}`
        : undefined
      : tokenBalance.data !== undefined
        ? `${formatAmount(tokenBalance.data)} ${symbol}`
        : undefined;

  return (
    <Card data-testid="trade-panel">
      <CardContent className="flex flex-col gap-4">
        <div className="grid grid-cols-2 gap-1 rounded-lg bg-muted/60 p-1" role="tablist" aria-label="Trade side">
          {(["buy", "sell"] as const).map((s) => (
            <button
              key={s}
              type="button"
              role="tab"
              aria-selected={side === s}
              disabled={busy !== null}
              onClick={() => switchSide(s)}
              className={cn(
                "rounded-md py-1.5 text-sm font-medium capitalize transition-colors",
                side === s
                  ? s === "buy"
                    ? "bg-emerald-600 text-white shadow-sm"
                    : "bg-red-600 text-white shadow-sm"
                  : "text-muted-foreground hover:text-foreground",
              )}
            >
              {s}
            </button>
          ))}
        </div>

        {side === "buy" && connected && !wrongChain && gate.canTrade === false ? (
          <div className="flex items-start gap-2 rounded-lg border border-red-500/30 bg-red-500/5 p-3 text-xs">
            <Lock className="mt-0.5 size-3.5 shrink-0 text-red-600 dark:text-red-400" />
            <p className="text-muted-foreground">
              <span className="font-medium text-foreground">Buying needs a Not-Lazarus Pass.</span>{" "}
              Insult Kim and claim yours on the{" "}
              <Link href={`${routes.launchpad}#pass`} className="underline underline-offset-4">
                launchpad page
              </Link>
              . Selling is open to everyone.
            </p>
          </div>
        ) : null}

        <div className="flex flex-col gap-2">
          <div className="flex items-baseline justify-between text-xs text-muted-foreground">
            <span>{side === "buy" ? `You pay (${unit})` : `You sell (${symbol})`}</span>
            {balanceLine ? <span>Balance: {balanceLine}</span> : null}
          </div>
          <Input
            value={amountText}
            onChange={(e) => {
              setAmountText(e.target.value);
              setLastError(null);
            }}
            inputMode="decimal"
            placeholder="0.0"
            autoComplete="off"
            aria-label={side === "buy" ? `Amount of ${unit} to spend` : `Amount of ${symbol} to sell`}
            aria-invalid={parsed.status === "invalid"}
            className="h-11 font-mono text-lg"
            disabled={busy !== null}
          />
          <div className="flex flex-wrap gap-1.5">
            {presets.map((p) => (
              <button
                key={p}
                type="button"
                disabled={busy !== null || (side === "sell" && !tokenBalance.data)}
                onClick={() => {
                  setLastError(null);
                  if (side === "buy") setAmountText(p);
                  else if (tokenBalance.data) setAmountText(toInputString((tokenBalance.data * BigInt(p)) / 100n));
                }}
                className="rounded-md bg-background px-2 py-1 text-xs ring-1 ring-foreground/10 hover:bg-muted disabled:opacity-50"
              >
                {side === "buy" ? `${p} ${unit}` : p === "100" ? "Max" : `${p}%`}
              </button>
            ))}
          </div>
        </div>

        {amount > 0n ? (
          <div className="flex flex-col gap-1 rounded-lg bg-muted/30 p-3 text-xs" data-testid="trade-quote">
            {quoteIsCurrent && quotedOut !== undefined ? (
              side === "buy" ? (
                <>
                  <span>
                    You get ≈{" "}
                    <span className="font-medium tabular-nums">
                      {formatAmount(buyTokensOut!)} ${symbol}
                    </span>
                  </span>
                  <span className="text-muted-foreground">
                    Minimum after {slippageBps / 100}%: {formatAmount(applySlippage(buyTokensOut!, slippageBps))} · fee{" "}
                    {formatAmount(buyFee ?? 0n)} {unit}
                    {feeBps !== undefined ? ` (${formatBps(feeBps)})` : ""}
                  </span>
                  {buyRefund !== undefined && buyRefund > 0n ? (
                    <span className="text-amber-700 dark:text-amber-400" data-testid="refund-note">
                      This buy finishes the curve. Only {formatAmount(buyAccepted ?? 0n)} {unit} is used;{" "}
                      {formatAmount(buyRefund)} {unit} is refunded in the same transaction, and ${symbol}{" "}
                      graduates to PancakeSwap.
                    </span>
                  ) : null}
                </>
              ) : (
                <>
                  <span>
                    You get ≈{" "}
                    <span className="font-medium tabular-nums">
                      {formatAmount(sellBnbOut!)} {unit}
                    </span>
                  </span>
                  <span className="text-muted-foreground">
                    Minimum after {slippageBps / 100}%: {formatAmount(applySlippage(sellBnbOut!, slippageBps))} {unit} ·
                    fee {formatAmount(sellFee ?? 0n)} {unit}
                  </span>
                </>
              )
            ) : activeQuote.isError ? (
              <span className="text-destructive">{describeError(activeQuote.error)}</span>
            ) : (
              <span className="text-muted-foreground">Fetching quote…</span>
            )}
          </div>
        ) : null}

        <TradeSettings
          slippageBps={slippageBps}
          onSlippageBps={setSlippageBps}
          deadlineMinutes={deadlineMinutes}
          onDeadlineMinutes={setDeadlineMinutes}
        />

        <WalletGate>
          <Button
            size="lg"
            className={cn(
              "w-full text-white",
              side === "buy" ? "bg-emerald-600 hover:bg-emerald-600/90" : "bg-red-600 hover:bg-red-600/90",
            )}
            disabled={busy !== null || Boolean(blocker)}
            onClick={() => void submit()}
          >
            <span className="truncate">
              {busy ?? blocker?.label ?? (side === "buy" ? `Buy $${symbol}` : `Sell $${symbol}`)}
            </span>
          </Button>
        </WalletGate>
        {blocker?.detail && !busy && connected && !wrongChain ? (
          <p className="text-xs text-muted-foreground">{blocker.detail}</p>
        ) : null}
        {lastError ? <p className="text-xs text-destructive">{lastError}</p> : null}
      </CardContent>
    </Card>
  );
}
