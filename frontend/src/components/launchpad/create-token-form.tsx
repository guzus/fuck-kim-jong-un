import { useMemo, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Lock } from "lucide-react";
import { toast } from "sonner";
import { isAddressEqual, parseEventLogs } from "viem";
import { useBalance, useGasPrice, useReadContract } from "wagmi";
import { readContract, simulateContract, writeContract } from "wagmi/actions";

import { Link } from "@/components/link";
import { MetadataLinks } from "@/components/launchpad/external-links";
import { TokenImage } from "@/components/launchpad/token-image";
import { TradeSettings } from "@/components/launchpad/trade-settings";
import { WalletGate } from "@/components/launchpad/wallet-gate";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { dprkLaunchpadAbi } from "@/lib/abi/launchpad";
import { launchpadConfig } from "@/lib/launchpad/config";
import { applySlippage } from "@/lib/launchpad/curve";
import { describeError } from "@/lib/launchpad/errors";
import { formatAmount, parseAmountInput, utf8Bytes } from "@/lib/launchpad/format";
import {
  retryUnlessRevert,
  useDebounced,
  useLaunchpadConstants,
  useLaunchpadWallet,
  useTradeGate,
} from "@/lib/launchpad/hooks";
import {
  METADATA_MAX_BYTES,
  NAME_MAX_BYTES,
  SYMBOL_MAX_BYTES,
  buildMetadataJson,
  cleanLabel,
  cleanText,
  parseTokenMetadata,
  toSafeTelegram,
  toSafeTwitter,
  toSafeUrl,
  toSafeWebsite,
} from "@/lib/launchpad/metadata";
import { navigate, routes } from "@/lib/router";
import {
  CREATE_AND_GRADUATE_GAS,
  DEFAULT_DEADLINE_MINUTES,
  DEFAULT_SLIPPAGE_BPS,
  PriceMovedError,
  submitDeadline,
  waitForSuccess,
} from "@/lib/launchpad/tx";
import { wagmiConfig } from "@/lib/wagmi";
import { cn } from "@/lib/utils";

const chainId = launchpadConfig.chainId;
const unit = launchpadConfig.nativeSymbol;

type Fields = {
  name: string;
  symbol: string;
  description: string;
  image: string;
  website: string;
  twitter: string;
  telegram: string;
  initialBuy: string;
};

const EMPTY: Fields = {
  name: "",
  symbol: "",
  description: "",
  image: "",
  website: "",
  twitter: "",
  telegram: "",
  initialBuy: "",
};

function Field({
  label,
  hint,
  error,
  counter,
  children,
}: {
  label: string;
  hint?: ReactNode;
  error?: string;
  counter?: { used: number; max: number };
  children: ReactNode;
}) {
  return (
    <label className="flex flex-col gap-1.5">
      <span className="flex items-baseline justify-between gap-2 text-sm font-medium">
        {label}
        {counter ? (
          <span
            className={cn(
              "font-mono text-[11px] font-normal tabular-nums",
              counter.used > counter.max ? "text-destructive" : "text-muted-foreground",
            )}
          >
            {counter.used}/{counter.max} bytes
          </span>
        ) : null}
      </span>
      {children}
      {error ? (
        <span className="text-xs text-destructive">{error}</span>
      ) : hint ? (
        <span className="text-xs text-muted-foreground">{hint}</span>
      ) : null}
    </label>
  );
}

/** A label is "clean" when stripping invisible/bidi/control characters doesn't change it. */
function labelError(value: string, maxBytes: number, what: string): string | undefined {
  const trimmed = value.trim();
  if (!trimmed) return `${what} is required.`;
  if (utf8Bytes(trimmed) > maxBytes) return `${what} is limited to ${maxBytes} bytes (UTF-8).`;
  if (cleanLabel(trimmed, 1000, "") !== trimmed.replace(/\s+/g, " ")) {
    return `${what} contains invisible, direction-override or stacked combining characters.`;
  }
  return undefined;
}

export function CreateTokenForm() {
  const [fields, setFields] = useState<Fields>(EMPTY);
  const [slippageBps, setSlippageBps] = useState(DEFAULT_SLIPPAGE_BPS);
  const [deadlineMinutes, setDeadlineMinutes] = useState(DEFAULT_DEADLINE_MINUTES);
  const [busy, setBusy] = useState<string | null>(null);
  const [submitError, setSubmitError] = useState<string | null>(null);

  const { account, connected, wrongChain } = useLaunchpadWallet();
  const gate = useTradeGate(account);
  const { constants } = useLaunchpadConstants();
  const queryClient = useQueryClient();
  const launchpad = launchpadConfig.addresses.launchpad!;

  const set = (key: keyof Fields) => (value: string) => {
    setSubmitError(null);
    setFields((f) => ({ ...f, [key]: value }));
  };

  const metadataJson = useMemo(() => buildMetadataJson(fields), [fields]);
  const metadataBytes = utf8Bytes(metadataJson);
  const preview = useMemo(() => parseTokenMetadata(metadataJson), [metadataJson]);

  const errors = {
    name: fields.name ? labelError(fields.name, NAME_MAX_BYTES, "Name") : undefined,
    symbol: fields.symbol ? labelError(fields.symbol, SYMBOL_MAX_BYTES, "Symbol") : undefined,
    image:
      fields.image.trim() && !toSafeUrl(fields.image)
        ? "Use an https:// or ipfs:// link (no credentials, no whitespace)."
        : undefined,
    website:
      fields.website.trim() && !toSafeWebsite(fields.website) ? "Use an https:// link." : undefined,
    twitter:
      fields.twitter.trim() && !toSafeTwitter(fields.twitter)
        ? "Use an @handle or an x.com / twitter.com link."
        : undefined,
    telegram:
      fields.telegram.trim() && !toSafeTelegram(fields.telegram)
        ? "Use a @handle or a t.me link."
        : undefined,
    metadata:
      metadataBytes > METADATA_MAX_BYTES
        ? `Description and links come to ${metadataBytes} bytes; the limit is ${METADATA_MAX_BYTES}.`
        : undefined,
  };

  const buy = parseAmountInput(fields.initialBuy);
  const buyValue = buy.status === "ok" ? buy.value : 0n;
  const debouncedBuy = useDebounced(buyValue);

  const balance = useBalance({
    address: account,
    chainId,
    query: { enabled: Boolean(account), refetchInterval: 15_000 },
  });

  const quote = useReadContract({
    address: launchpad,
    abi: dprkLaunchpadAbi,
    functionName: "quoteCreateBuy",
    args: [debouncedBuy],
    chainId,
    query: { enabled: debouncedBuy > 0n, refetchInterval: 10_000, retry: retryUnlessRevert },
  });
  const quoteIsCurrent = debouncedBuy === buyValue && quote.data !== undefined && !quote.isError;
  const [quotedTokens, quotedFee, , quotedRefund] = quote.data ?? [];

  const hasFieldErrors = Object.values(errors).some(Boolean) || buy.status === "invalid";
  const missingRequired = !fields.name.trim() || !fields.symbol.trim();
  // Buying the whole curve goes out with CREATE_AND_GRADUATE_GAS (see submit), and the wallet wants
  // value + limit × gas price up front, so count that here and explain it instead of the wallet's error.
  const gasPrice = useGasPrice({ chainId, query: { enabled: buyValue > 0n, refetchInterval: 30_000 } });
  const takesWholeCurve =
    quoteIsCurrent && ((quotedRefund ?? 0n) > 0n || (constants !== undefined && quotedTokens === constants.curveSupply));
  const gasReserve = takesWholeCurve && gasPrice.data !== undefined ? CREATE_AND_GRADUATE_GAS * gasPrice.data : 0n;
  const overBalance = balance.data !== undefined && buyValue + gasReserve > balance.data.value;

  let blocker: string | undefined;
  if (gate.paused) blocker = "The launchpad is paused. Launching is off for now.";
  else if (gate.canTrade === false) blocker = "Pass holders only. Insult Kim and claim your pass first.";
  else if (missingRequired) blocker = "Name and symbol are required.";
  else if (hasFieldErrors) blocker = "Fix the highlighted fields.";
  else if (overBalance)
    blocker =
      gasReserve > 0n
        ? `Not enough ${unit} for the initial buy plus up to ${formatAmount(gasReserve)} ${unit} of gas: buying the whole curve graduates it in the same transaction.`
        : `Not enough ${unit} for the initial buy.`;
  else if (buyValue > 0n && !quoteIsCurrent) blocker = quote.isError ? describeError(quote.error) : "Fetching quote…";

  async function submit() {
    if (!account || blocker || busy) return;
    setSubmitError(null);
    const name = fields.name.trim().replace(/\s+/g, " ");
    const symbol = fields.symbol.trim().replace(/\s+/g, " ");
    try {
      // Premise: quotes go stale. Re-quote now and derive min-out from that, not from what's on screen.
      let minTokensOut = 0n;
      let gas: bigint | undefined;
      if (buyValue > 0n) {
        setBusy("Refreshing quote…");
        const [fresh, , , freshRefund] = await readContract(wagmiConfig, {
          address: launchpad,
          abi: dprkLaunchpadAbi,
          functionName: "quoteCreateBuy",
          args: [buyValue],
          chainId,
        });
        if (quotedTokens !== undefined && fresh < applySlippage(quotedTokens, slippageBps)) {
          await queryClient.invalidateQueries();
          throw new PriceMovedError();
        }
        minTokensOut = applySlippage(fresh, slippageBps);
        // Buying the whole curve graduates it in this transaction. Nobody can trade the new curve first, but
        // the token's address depends on how many launches land before this one, and anyone can create the
        // PancakeSwap pair for an address in advance. An estimate taken while such a pair exists is millions
        // of gas short if another launch lands first and this token gets an address without one.
        if (freshRefund > 0n || fresh === constants?.curveSupply) gas = CREATE_AND_GRADUATE_GAS;
      }
      const deadline = await submitDeadline(deadlineMinutes);

      setBusy("Simulating…");
      const { request } = await simulateContract(wagmiConfig, {
        address: launchpad,
        abi: dprkLaunchpadAbi,
        functionName: "createToken",
        args: [name, symbol, metadataJson, minTokensOut, deadline],
        value: buyValue,
        gas,
        chainId,
        account,
      });
      setBusy("Confirm in wallet…");
      const hash = await writeContract(wagmiConfig, request);
      setBusy("Deploying your token…");
      const receipt = await waitForSuccess(hash);

      // Only trust TokenCreated emitted by the launchpad itself, for this creator. A create-buy that
      // completes the curve also carries PancakeSwap logs in the same receipt.
      const created = parseEventLogs({ abi: dprkLaunchpadAbi, eventName: "TokenCreated", logs: receipt.logs }).find(
        (log) => isAddressEqual(log.address, launchpad) && isAddressEqual(log.args.creator, account),
      );
      if (!created) throw new Error("The token was created, but its TokenCreated event wasn't in the receipt.");

      toast.success(`$${cleanLabel(symbol, 16)} is live. Lazarus not invited.`);
      void queryClient.invalidateQueries();
      navigate(routes.token(created.args.token));
    } catch (error) {
      const message = error instanceof PriceMovedError ? error.message : describeError(error);
      setSubmitError(message);
      toast.error(message);
    } finally {
      setBusy(null);
    }
  }

  const previewName = cleanLabel(fields.name, 64, "Your token");
  const previewSymbol = cleanLabel(fields.symbol, 16, "TICKER");
  const supplyShareBps =
    quotedTokens !== undefined && constants && constants.totalSupply > 0n
      ? Number((quotedTokens * 10_000n) / constants.totalSupply)
      : undefined;

  return (
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_20rem]">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Token details</CardTitle>
          <CardDescription>
            Name and symbol live in the token contract forever. Description and links are stored as
            JSON metadata, capped at {METADATA_MAX_BYTES} bytes on-chain.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <form
            className="flex flex-col gap-4"
            onSubmit={(e) => {
              e.preventDefault();
              void submit();
            }}
          >
            <fieldset disabled={busy !== null} className="flex flex-col gap-4">
              <div className="grid gap-4 sm:grid-cols-[minmax(0,1fr)_12rem]">
                <Field
                  label="Name"
                  error={errors.name}
                  counter={{ used: utf8Bytes(fields.name.trim()), max: NAME_MAX_BYTES }}
                >
                  <Input
                    value={fields.name}
                    onChange={(e) => set("name")(e.target.value)}
                    placeholder="Supreme Leader Inu"
                    autoComplete="off"
                    aria-invalid={Boolean(errors.name)}
                  />
                </Field>
                <Field
                  label="Symbol"
                  error={errors.symbol}
                  counter={{ used: utf8Bytes(fields.symbol.trim()), max: SYMBOL_MAX_BYTES }}
                >
                  <Input
                    value={fields.symbol}
                    onChange={(e) => set("symbol")(e.target.value.replace(/^\$/, ""))}
                    placeholder="KIMINU"
                    autoComplete="off"
                    className="font-mono"
                    aria-invalid={Boolean(errors.symbol)}
                  />
                </Field>
              </div>
              <Field label="Description" hint="Plain text. Links in here won't be clickable.">
                <textarea
                  value={fields.description}
                  onChange={(e) => set("description")(e.target.value)}
                  rows={3}
                  placeholder="The only coin the Supreme Leader can't buy."
                  className="w-full min-w-0 rounded-lg border border-input bg-transparent px-2.5 py-1.5 text-base outline-none placeholder:text-muted-foreground focus-visible:border-ring focus-visible:ring-3 focus-visible:ring-ring/50 md:text-sm dark:bg-input/30"
                />
              </Field>
              <Field label="Image URL" hint="https:// or ipfs://. Square images look best." error={errors.image}>
                <Input
                  value={fields.image}
                  onChange={(e) => set("image")(e.target.value)}
                  placeholder="ipfs://bafy… or https://…"
                  autoComplete="off"
                  aria-invalid={Boolean(errors.image)}
                />
              </Field>
              <div className="grid gap-4 sm:grid-cols-3">
                <Field label="Website" error={errors.website}>
                  <Input
                    value={fields.website}
                    onChange={(e) => set("website")(e.target.value)}
                    placeholder="https://"
                    autoComplete="off"
                    aria-invalid={Boolean(errors.website)}
                  />
                </Field>
                <Field label="X" error={errors.twitter}>
                  <Input
                    value={fields.twitter}
                    onChange={(e) => set("twitter")(e.target.value)}
                    placeholder="@handle"
                    autoComplete="off"
                    aria-invalid={Boolean(errors.twitter)}
                  />
                </Field>
                <Field label="Telegram" error={errors.telegram}>
                  <Input
                    value={fields.telegram}
                    onChange={(e) => set("telegram")(e.target.value)}
                    placeholder="@group"
                    autoComplete="off"
                    aria-invalid={Boolean(errors.telegram)}
                  />
                </Field>
              </div>
              <p
                className={cn(
                  "font-mono text-[11px] tabular-nums",
                  errors.metadata ? "text-destructive" : "text-muted-foreground",
                )}
              >
                metadata: {metadataBytes}/{METADATA_MAX_BYTES} bytes
                {errors.metadata ? ` · ${errors.metadata}` : ""}
              </p>

              <div className="flex flex-col gap-3 rounded-lg bg-muted/30 p-3">
                <Field
                  label={`Initial buy (optional, ${unit})`}
                  error={buy.status === "invalid" ? buy.message : undefined}
                  hint={
                    balance.data
                      ? `Balance: ${formatAmount(balance.data.value)} ${unit}. Buying first in the same transaction means nobody can snipe your launch.`
                      : "Buying first in the same transaction means nobody can snipe your launch."
                  }
                >
                  <Input
                    value={fields.initialBuy}
                    onChange={(e) => set("initialBuy")(e.target.value)}
                    inputMode="decimal"
                    placeholder="0.0"
                    autoComplete="off"
                    className="font-mono"
                    aria-invalid={buy.status === "invalid"}
                  />
                </Field>
                {buyValue > 0n ? (
                  <div className="flex flex-col gap-1 text-xs" data-testid="create-quote">
                    {quoteIsCurrent && quotedTokens !== undefined ? (
                      <>
                        <span>
                          You get ≈{" "}
                          <span className="font-medium tabular-nums">
                            {formatAmount(quotedTokens)} ${previewSymbol}
                          </span>
                          {supplyShareBps !== undefined ? ` (${(supplyShareBps / 100).toFixed(2)}% of supply)` : ""}
                        </span>
                        <span className="text-muted-foreground">
                          Minimum after {slippageBps / 100}% slippage:{" "}
                          {formatAmount(applySlippage(quotedTokens, slippageBps))} · fee{" "}
                          {formatAmount(quotedFee ?? 0n)} {unit}
                        </span>
                        {quotedRefund && quotedRefund > 0n ? (
                          <span className="text-amber-700 dark:text-amber-400">
                            This buys out the whole curve: {formatAmount(quotedRefund)} {unit} comes back as a
                            refund and the token graduates to PancakeSwap in the same transaction.
                          </span>
                        ) : null}
                      </>
                    ) : quote.isError ? (
                      <span className="text-destructive">{describeError(quote.error)}</span>
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
              </div>
            </fieldset>

            {connected && !wrongChain && gate.canTrade === false ? (
              <div className="flex items-start gap-2 rounded-lg border border-red-500/30 bg-red-500/5 p-3 text-sm">
                <Lock className="mt-0.5 size-4 shrink-0 text-red-600 dark:text-red-400" />
                <p className="text-muted-foreground">
                  <span className="font-medium text-foreground">Pass holders only.</span> Prove you
                  aren&apos;t Lazarus first: call pig() and fuck() and claim your pass on the{" "}
                  <Link href={`${routes.launchpad}#pass`} className="underline underline-offset-4">
                    launchpad page
                  </Link>
                  .
                </p>
              </div>
            ) : null}

            <WalletGate>
              <Button type="submit" size="lg" className="w-full" disabled={busy !== null || Boolean(blocker)}>
                {busy ?? (buyValue > 0n ? "Launch and buy" : "Launch token")}
              </Button>
            </WalletGate>
            {blocker && connected && !wrongChain && !busy ? (
              <p className="text-center text-xs text-muted-foreground">{blocker}</p>
            ) : null}
            {submitError ? <p className="text-sm text-destructive">{submitError}</p> : null}
          </form>
        </CardContent>
      </Card>

      <aside className="flex flex-col gap-3">
        <span className="text-xs font-medium uppercase tracking-widest text-muted-foreground">Preview</span>
        <div className="flex min-w-0 flex-col gap-3 rounded-xl bg-card p-4 ring-1 ring-foreground/10">
          <div className="flex min-w-0 items-start gap-3">
            <TokenImage
              src={preview.image}
              symbol={previewSymbol}
              seed="0x7a1e5f000000"
              className="size-14 text-xl"
            />
            <div className="flex min-w-0 flex-col gap-0.5">
              <bdi className="truncate font-heading font-semibold">{previewName}</bdi>
              <bdi className="truncate font-mono text-xs text-muted-foreground">${previewSymbol}</bdi>
            </div>
          </div>
          <p className="max-h-40 overflow-y-auto whitespace-pre-line text-xs text-muted-foreground [overflow-wrap:anywhere]">
            {cleanText(fields.description, METADATA_MAX_BYTES) ?? "No description."}
          </p>
          <MetadataLinks metadata={preview} />
        </div>
        <p className="text-xs text-muted-foreground">
          This is exactly what other people will see: links that aren&apos;t https (or ipfs for the
          image) are dropped, and invisible or direction-flipping characters are stripped.
        </p>
      </aside>
    </div>
  );
}
