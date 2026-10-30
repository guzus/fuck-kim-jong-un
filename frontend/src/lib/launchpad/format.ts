import { formatUnits, parseUnits } from "viem";

const SUBSCRIPT_DIGITS = "₀₁₂₃₄₅₆₇₈₉";

function subscript(n: number): string {
  return String(n)
    .split("")
    .map((d) => SUBSCRIPT_DIGITS[Number(d)])
    .join("");
}

const compactFmt = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 2 });
const groupedFmt2 = new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 });
const groupedFmt4 = new Intl.NumberFormat("en-US", { maximumFractionDigits: 4 });
const sigFmt = new Intl.NumberFormat("en-US", { maximumSignificantDigits: 4 });

/**
 * Human formatting for 18-decimal amounts. Big values go compact (12.35M), mid values get grouped
 * decimals, and tiny ones use subscript-zero notation (0.0₇75) instead of a wall of zeros.
 */
export function formatAmount(value: bigint, decimals = 18, options: { compact?: boolean } = {}): string {
  if (value === 0n) return "0";
  if (value < 0n) return `-${formatAmount(-value, decimals, options)}`;
  const text = formatUnits(value, decimals);
  const n = Number(text);
  if (options.compact !== false && n >= 1_000_000) return compactFmt.format(n);
  if (n >= 1000) return groupedFmt2.format(n);
  if (n >= 1) return groupedFmt4.format(n);
  const [, fraction = ""] = text.split(".");
  const zeros = fraction.length - fraction.replace(/^0+/, "").length;
  if (zeros < 4) return sigFmt.format(n);
  const digits = fraction.slice(zeros, zeros + 4).replace(/0+$/, "");
  return `0.0${subscript(zeros)}${digits}`;
}

export function formatBps(bps: number | bigint): string {
  const value = Number(bps) / 100;
  if (value === 0 || value === 100) return `${value}%`;
  return `${value < 10 ? value.toFixed(2) : value.toFixed(1)}%`;
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export function timeAgo(unixSeconds: bigint | number, nowMs = Date.now()): string {
  const seconds = Math.max(0, Math.floor(nowMs / 1000 - Number(unixSeconds)));
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}

export type ParsedAmount =
  | { status: "empty" }
  | { status: "invalid"; message: string }
  | { status: "ok"; value: bigint };

/** Parses a user-typed decimal amount. Strict: digits and one dot, no exponents, no locale commas. */
export function parseAmountInput(raw: string, decimals = 18): ParsedAmount {
  const text = raw.trim();
  if (text === "") return { status: "empty" };
  if (text.length > 40 || !/^\d*\.?\d*$/.test(text) || text === ".") {
    return { status: "invalid", message: "Enter a plain number, like 0.25" };
  }
  const [, fraction = ""] = text.split(".");
  if (fraction.length > decimals) {
    return { status: "invalid", message: `At most ${decimals} decimal places` };
  }
  return { status: "ok", value: parseUnits(text.startsWith(".") ? `0${text}` : text, decimals) };
}

/** Exact decimal string for putting a bigint back into an input (no rounding, no grouping). */
export function toInputString(value: bigint, decimals = 18): string {
  return formatUnits(value, decimals);
}

export function utf8Bytes(text: string): number {
  return new TextEncoder().encode(text).length;
}
