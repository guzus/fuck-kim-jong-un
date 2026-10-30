// Bonding-curve display math. The contract is the source of truth for anything that moves funds (quotes
// come from quoteBuy/quoteSell/quoteCreateBuy); these helpers only turn reserves into display numbers.

export const BPS = 10_000n;
/** DprkToken is a plain 18-decimal ERC-20 (TOTAL_SUPPLY is 1e9 * 1e18). */
export const TOKEN_DECIMALS = 18;

export type CurveState = {
  creator: `0x${string}`;
  createdAt: bigint;
  graduated: boolean;
  pair: `0x${string}`;
  virtualBnbReserve: bigint;
  virtualTokenReserve: bigint;
  realBnbReserve: bigint;
  realTokenReserve: bigint;
};

export type TokenInfo = {
  token: `0x${string}`;
  name: string;
  symbol: string;
  metadata: string;
  state: CurveState;
};

/** Spot price in BNB per whole token, as an 18-decimal fixed-point bigint. */
export function spotPriceE18(state: CurveState): bigint | undefined {
  if (state.virtualTokenReserve === 0n) return undefined;
  return (state.virtualBnbReserve * 10n ** 18n) / state.virtualTokenReserve;
}

/** Fully diluted market cap in wei: spot price × TOTAL_SUPPLY. */
export function marketCapWei(state: CurveState, totalSupply: bigint): bigint | undefined {
  if (state.virtualTokenReserve === 0n) return undefined;
  return (state.virtualBnbReserve * totalSupply) / state.virtualTokenReserve;
}

/** Share of CURVE_SUPPLY sold, in basis points. Mirrors the contract's progressBps(). */
export function progressBps(state: CurveState, curveSupply: bigint): number {
  if (state.graduated) return 10_000;
  if (curveSupply === 0n) return 0;
  const sold = curveSupply > state.realTokenReserve ? curveSupply - state.realTokenReserve : 0n;
  const bps = (sold * BPS) / curveSupply;
  return Number(bps > BPS ? BPS : bps);
}

/** Minimum acceptable output for a quote, rounding down. */
export function applySlippage(amount: bigint, slippageBps: number): bigint {
  const bps = BigInt(Math.min(Math.max(Math.round(slippageBps), 0), 10_000));
  return (amount * (BPS - bps)) / BPS;
}
