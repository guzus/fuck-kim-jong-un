import type { Hash, ReplacementReason, TransactionReceipt } from "viem";
import { getBlock, getPublicClient } from "wagmi/actions";

import { launchpadConfig } from "@/lib/launchpad/config";
import { wagmiConfig } from "@/lib/wagmi";

export const DEFAULT_SLIPPAGE_BPS = 200; // 2%
export const DEFAULT_DEADLINE_MINUTES = 10;

/**
 * Gas limit for a buy that may finish the curve (see mayCompleteCurve). Graduation creates the PancakeSwap
 * pair inside that buy: on a BSC mainnet fork it used 3,562,919 gas and needed a 3.63M limit (about 2.4M with
 * the local mock factory), against 70-90k for a plain buy. A wallet estimates gas against the latest block,
 * so a buy estimated while it didn't finish the curve, then mined right behind another buy that left the
 * curve just short, runs out of gas. BSC charges for the gas used, not the limit, so headroom costs nothing.
 */
export const GRADUATING_BUY_GAS = 4_500_000n;

/**
 * Gas limit for a createToken whose initial buy takes the whole curve, so it deploys the token and graduates
 * it in one go: on a BSC mainnet fork that needed a 4.51M limit, 5.28M with the full 1 KB of metadata.
 */
export const CREATE_AND_GRADUATE_GAS = 7_000_000n;

/**
 * Deadline for a trade, computed when the user submits (never when the quote was rendered). The contract
 * compares against block.timestamp, so "now" is the later of the local clock and the latest block: a
 * chain that runs ahead of this machine (anvil after evm_increaseTime, a skewed laptop clock) must not
 * produce a deadline that's already expired.
 */
export async function submitDeadline(minutes: number): Promise<bigint> {
  let now = BigInt(Math.floor(Date.now() / 1000));
  try {
    const block = await getBlock(wagmiConfig, { chainId: launchpadConfig.chainId });
    if (block.timestamp > now) now = block.timestamp;
  } catch {
    // fall back to the local clock
  }
  const seconds = Math.round(Math.min(Math.max(minutes, 1), 24 * 60) * 60);
  return now + BigInt(seconds);
}

export class TxRevertedError extends Error {
  readonly hash: Hash;
  constructor(hash: Hash, outOfGas = false) {
    super(outOfGas ? "The transaction ran out of gas and reverted." : "The transaction was mined but reverted.");
    this.hash = hash;
  }
}

/** Waits for a launchpad-chain transaction and throws if it reverted or the wallet replaced it. */
export async function waitForSuccess(hash: Hash): Promise<TransactionReceipt> {
  // viem's waiter, not wagmi's: on a revert, wagmi re-runs the call on top of the block the transaction was
  // mined in and throws whatever that returns. That describes the chain after the fact (AlreadyGraduated
  // once another buy finished the curve, "unknown reason", or an empty message when the re-run succeeds).
  const client = getPublicClient(wagmiConfig, { chainId: launchpadConfig.chainId });
  if (!client) throw new Error("No client for the launchpad chain");
  const replaced: { reason?: ReplacementReason } = {};
  const receipt = await client.waitForTransactionReceipt({
    hash,
    timeout: 0,
    onReplaced: ({ reason }) => {
      replaced.reason = reason;
    },
  });
  // A speed-up ("repriced") is the same call. A cancel (a 0-value send to self) or any other replacement
  // succeeds on its own, so its receipt says nothing about what the user asked for.
  if (replaced.reason === "cancelled") throw new Error("The transaction was cancelled in your wallet.");
  if (replaced.reason === "replaced") throw new Error("Your wallet replaced the transaction with a different one.");
  if (receipt.status !== "success") {
    // Running out of gas burns the whole limit except the 1/64 each outer call keeps back (EIP-150), so
    // ~97% even two calls deep (launchpad -> factory -> CREATE2); a revert in the contract logic uses less.
    const mined = receipt.transactionHash;
    const tx = await client.getTransaction({ hash: mined }).catch(() => undefined);
    throw new TxRevertedError(mined, tx !== undefined && receipt.gasUsed * 100n >= tx.gas * 95n);
  }
  return receipt;
}

/**
 * Guards against signing a price the user never saw: the min-out comes from a fresh quote taken at
 * submit time, but if that fresh quote is already worse than the displayed one by more than the
 * slippage tolerance, stop and let the user look at the new number first.
 */
export class PriceMovedError extends Error {
  constructor() {
    super("The price moved more than your slippage tolerance since the quote you saw. Check the new quote and try again.");
  }
}
