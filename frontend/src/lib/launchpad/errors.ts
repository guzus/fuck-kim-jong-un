import {
  BaseError,
  ChainMismatchError,
  ContractFunctionRevertedError,
  ContractFunctionZeroDataError,
  HttpRequestError,
  InsufficientFundsError,
  UserRejectedRequestError,
  decodeErrorResult,
  parseAbi,
  type Abi,
  type Hex,
} from "viem";

import { dprkLaunchpadAbi, dprkPassAbi, dprkTokenAbi } from "@/lib/abi/launchpad";
import { chainLabel, launchpadConfig } from "@/lib/launchpad/config";

// Errors a launchpad transaction can bubble up from deeper calls (the token, OpenZeppelin bases). The
// generated interface ABIs don't list the OpenZeppelin ones, so they're added here for decoding only.
const extraErrors = parseAbi([
  "error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)",
  "error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)",
  "error ERC20InvalidReceiver(address receiver)",
  "error ERC20InvalidSender(address sender)",
  "error ERC20InvalidSpender(address spender)",
  "error ERC721NonexistentToken(uint256 tokenId)",
  "error ReentrancyGuardReentrantCall()",
  "error OwnableUnauthorizedAccount(address account)",
  "error EnforcedPause()",
  "error SafeERC20FailedOperation(address token)",
  "error FailedCall()",
]);

const allErrors: Abi = [...dprkLaunchpadAbi, ...dprkPassAbi, ...dprkTokenAbi, ...extraErrors].filter(
  (item) => item.type === "error",
);

const COPY: Record<string, string> = {
  NotCertified:
    "This wallet has no Not-Lazarus Pass yet. Call pig() and fuck() on Kim, then claim your pass.",
  LaunchpadPaused: "The launchpad is paused, so launching and buying are off. Selling still works.",
  EnforcedPause: "The launchpad is paused, so launching and buying are off. Selling still works.",
  SlippageExceeded:
    "The price moved past your slippage limit before the trade landed. Try again or raise slippage.",
  DeadlineExpired: "The transaction deadline passed before it was mined. Send it again.",
  AlreadyGraduated: "This token already graduated. Trade it on PancakeSwap.",
  TransferLocked:
    "Before graduation, curve tokens can only move to pass holders or back to the launchpad.",
  UnknownToken: "That address isn't a DPRK.FUN launchpad token.",
  InvalidMetadata: "Name, symbol or metadata is empty or longer than the contract allows.",
  ZeroAmount: "Enter an amount above zero.",
  DustAmount: "That amount is too small to trade on the curve.",
  InsufficientRealBnbReserve: "The curve doesn't hold enough BNB to pay out that sell.",
  BnbTransferFailed: "The BNB transfer failed.",
  NotPiggedAndFucked: "Call both pig() and fuck() on the registry before claiming the pass.",
  AlreadyCertified: "This wallet already holds a pass.",
  Soulbound: "Passes are soulbound and can't be transferred.",
  OnlyLaunchpad: "Only the launchpad can do that.",
  ERC20InsufficientBalance: "You don't have that many tokens.",
  ERC20InsufficientAllowance: "Approve the launchpad to spend your tokens first.",
  ReentrancyGuardReentrantCall: "Reentrant call blocked.",
  NoFeesAccrued: "There are no fees to claim.",
};

function errorName(revert: ContractFunctionRevertedError): string | undefined {
  if (revert.data?.errorName) return revert.data.errorName;
  const raw = revert.raw as Hex | undefined;
  if (!raw || raw === "0x") return undefined;
  try {
    return decodeErrorResult({ abi: allErrors, data: raw }).errorName;
  } catch {
    return undefined;
  }
}

/** The custom error name behind a failed call, if there is one (e.g. "UnknownToken"). */
export function revertName(error: unknown): string | undefined {
  if (!(error instanceof BaseError)) return undefined;
  const revert = error.walk((e) => e instanceof ContractFunctionRevertedError);
  return revert instanceof ContractFunctionRevertedError ? errorName(revert) : undefined;
}

/** True when the failure is a contract revert (not a network/RPC problem), so retrying won't help. */
export function isRevert(error: unknown): boolean {
  return (
    error instanceof BaseError &&
    Boolean(error.walk((e) => e instanceof ContractFunctionRevertedError || e instanceof ContractFunctionZeroDataError))
  );
}

/** Human copy for anything a launchpad read or write can throw. Output is plain text. */
export function describeError(error: unknown): string {
  if (!(error instanceof BaseError)) {
    if (error instanceof Error) return error.message.slice(0, 300);
    return "Something went wrong.";
  }
  const rejected = error.walk(
    (e) => e instanceof UserRejectedRequestError || (e as { code?: unknown }).code === 4001,
  );
  if (rejected) return "You rejected the request in your wallet.";

  const revert = error.walk((e) => e instanceof ContractFunctionRevertedError);
  if (revert instanceof ContractFunctionRevertedError) {
    const name = errorName(revert);
    if (name && COPY[name]) return COPY[name];
    if (name) return `The contract reverted with ${name}.`;
    if (revert.reason) return `The contract reverted: ${revert.reason.slice(0, 200)}`;
    return "The contract reverted.";
  }
  if (error.walk((e) => e instanceof ContractFunctionZeroDataError)) {
    return `No contract answered at that address on ${chainLabel(launchpadConfig.chain)}. Check the VITE_DPRK_* addresses.`;
  }
  if (error.walk((e) => e instanceof ChainMismatchError)) {
    return `Your wallet is on the wrong network. Switch to ${chainLabel(launchpadConfig.chain)} and try again.`;
  }
  if (error.walk((e) => e instanceof InsufficientFundsError)) {
    return `Not enough ${launchpadConfig.nativeSymbol} to cover the amount plus gas.`;
  }
  if (error.walk((e) => e instanceof HttpRequestError)) {
    return "The RPC didn't answer. Check your connection and try again.";
  }
  return (error.shortMessage || error.message).slice(0, 300);
}
