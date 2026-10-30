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

/**
 * Whether a buy could finish the curve, and so graduate it, by the time it's mined. Trades that land first
 * can leave the curve anywhere, but a buy that finishes the curve gets exactly the tokens left, so it only
 * succeeds if at least `minTokensOut` are left. Its cheapest way to finish is when exactly that many are
 * left, and those last tokens cost k/F − k/(F + minTokensOut) BNB, where F is the virtual token reserve at
 * sell-out and k = x·y. A buy whose net BNB is below that can't graduate without failing its own min-out.
 * F is fixed per curve and k never decreases, so a stale `state` only makes this answer yes more often.
 */
export function mayCompleteCurve(state: CurveState, netBnbIn: bigint, minTokensOut: bigint): boolean {
  const finalTokenReserve = state.virtualTokenReserve - state.realTokenReserve;
  const k = state.virtualBnbReserve * state.virtualTokenReserve;
  return netBnbIn * finalTokenReserve * (finalTokenReserve + minTokensOut) >= k * minTokensOut;
}

/** Minimum acceptable output for a quote, rounding down. */
export function applySlippage(amount: bigint, slippageBps: number): bigint {
  const bps = BigInt(Math.min(Math.max(Math.round(slippageBps), 0), 10_000));
  return (amount * (BPS - bps)) / BPS;
}
