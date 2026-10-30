import type { Hash, TransactionReceipt } from "viem";
import { getBlock, waitForTransactionReceipt } from "wagmi/actions";

import { launchpadConfig } from "@/lib/launchpad/config";
import { wagmiConfig } from "@/lib/wagmi";

export const DEFAULT_SLIPPAGE_BPS = 200; // 2%
export const DEFAULT_DEADLINE_MINUTES = 10;

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
  constructor(hash: Hash) {
    super("The transaction was mined but reverted.");
    this.hash = hash;
  }
}

/** Waits for a launchpad-chain transaction and throws if it reverted. */
export async function waitForSuccess(hash: Hash): Promise<TransactionReceipt> {
  const receipt = await waitForTransactionReceipt(wagmiConfig, {
    hash,
    chainId: launchpadConfig.chainId,
  });
  if (receipt.status !== "success") throw new TxRevertedError(hash);
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
