import { useEffect, useState } from "react";
import { isAddressEqual, zeroAddress, type Address } from "viem";
import { useConnection, useReadContract, useReadContracts, useSwitchChain } from "wagmi";

import { dprkLaunchpadAbi, dprkPassAbi } from "@/lib/abi/launchpad";
import { kimJongUnAbi } from "@/lib/contract";
import { launchpadConfig } from "@/lib/launchpad/config";
import { isRevert } from "@/lib/launchpad/errors";

const chainId = launchpadConfig.chainId;

/** react-query retry policy: a revert won't change on retry, an RPC hiccup might. */
export function retryUnlessRevert(failureCount: number, error: unknown): boolean {
  return !isRevert(error) && failureCount < 2;
}

function nonZero(address: Address | undefined): Address | undefined {
  return address && address !== zeroAddress ? address : undefined;
}

/**
 * Contract addresses for the launchpad chain. The chain is the source of truth: the pass is whatever
 * `launchpad.pass()` gates on and the registry is whatever `pass.kimJongUn()` checks in `claim()`. The env
 * values are used until those reads land (and when they fail); a disagreement is surfaced, not hidden.
 */
export function useLaunchpadAddresses() {
  const { addresses } = launchpadConfig;
  const launchpad = launchpadConfig.isDeployed ? addresses.launchpad : undefined;

  const passRead = useReadContract({
    address: launchpad,
    abi: dprkLaunchpadAbi,
    functionName: "pass",
    chainId,
    query: { enabled: Boolean(launchpad), staleTime: Infinity, retry: retryUnlessRevert },
  });
  const pass = nonZero(passRead.data) ?? addresses.pass;

  const kimRead = useReadContract({
    address: pass,
    abi: dprkPassAbi,
    functionName: "kimJongUn",
    chainId,
    query: { enabled: Boolean(pass), staleTime: Infinity, retry: retryUnlessRevert },
  });
  const kimJongUn = nonZero(kimRead.data) ?? addresses.kimJongUn;

  const warnings: string[] = [];
  if (passRead.data && addresses.pass && !isAddressEqual(passRead.data, addresses.pass)) {
    warnings.push("VITE_DPRK_PASS_ADDRESS doesn't match launchpad.pass(); using the on-chain pass.");
  }
  if (kimRead.data && addresses.kimJongUn && !isAddressEqual(kimRead.data, addresses.kimJongUn)) {
    warnings.push(
      "VITE_DPRK_KIM_JONG_UN_ADDRESS doesn't match pass.kimJongUn(); using the registry the pass checks.",
    );
  }

  return {
    launchpad,
    pass,
    kimJongUn,
    warnings,
    /** Set when the launchpad address doesn't answer like a launchpad (wrong address or chain). */
    error: passRead.error,
    isLoading: passRead.isLoading,
  };
}

/** Values fixed at deployment. Read once. */
export function useLaunchpadConstants() {
  const launchpad = launchpadConfig.isDeployed ? launchpadConfig.addresses.launchpad : undefined;
  const contract = { address: launchpad ?? zeroAddress, abi: dprkLaunchpadAbi, chainId } as const;
  const { data, error, isLoading } = useReadContracts({
    contracts: [
      { ...contract, functionName: "TOTAL_SUPPLY" },
      { ...contract, functionName: "CURVE_SUPPLY" },
      { ...contract, functionName: "graduationBnb" },
      { ...contract, functionName: "feeBps" },
    ],
    allowFailure: false,
    query: { enabled: Boolean(launchpad), staleTime: Infinity, retry: retryUnlessRevert },
  });
  const [totalSupply, curveSupply, graduationBnb, feeBps] = data ?? [];
  return {
    constants:
      data === undefined
        ? undefined
        : { totalSupply: totalSupply!, curveSupply: curveSupply!, graduationBnb: graduationBnb!, feeBps: Number(feeBps!) },
    error,
    isLoading,
  };
}

/** pig / fuck / pass status for one account on the launchpad chain. */
export function usePassStatus(account: Address | undefined) {
  const { pass, kimJongUn } = useLaunchpadAddresses();
  const who = account ?? zeroAddress;
  const enabled = Boolean(account && pass && kimJongUn);
  const registry = { address: kimJongUn ?? zeroAddress, abi: kimJongUnAbi, chainId } as const;
  const passContract = { address: pass ?? zeroAddress, abi: dprkPassAbi, chainId } as const;

  const status = useReadContracts({
    contracts: [
      { ...registry, functionName: "hasPiggedKimJongUn", args: [who] },
      { ...registry, functionName: "hasFuckedKimJongUn", args: [who] },
      { ...passContract, functionName: "isCertified", args: [who] },
      { ...passContract, functionName: "passOf", args: [who] },
    ],
    allowFailure: false,
    query: { enabled, refetchInterval: 15_000, retry: retryUnlessRevert },
  });
  const [pigged, fucked, certified, passId] = status.data ?? [];

  const tokenUri = useReadContract({
    ...passContract,
    functionName: "tokenURI",
    args: [passId ?? 0n],
    query: { enabled: Boolean(pass && passId && passId > 0n), staleTime: Infinity, retry: retryUnlessRevert },
  });

  const claimed = useReadContract({
    ...passContract,
    functionName: "totalClaimed",
    query: { enabled: Boolean(pass), refetchInterval: 30_000, retry: retryUnlessRevert },
  });

  return {
    pass,
    kimJongUn,
    pigged,
    fucked,
    certified,
    passId: passId && passId > 0n ? passId : undefined,
    tokenUri: tokenUri.data,
    totalClaimed: claimed.data,
    isLoading: status.isLoading,
    error: status.error,
  };
}

/** Wallet state relative to the launchpad chain. */
export function useLaunchpadWallet() {
  const { address, status, chainId: walletChainId } = useConnection();
  const { mutate: switchChain, isPending: isSwitching } = useSwitchChain();
  const connected = status === "connected" && Boolean(address);
  return {
    account: connected ? address : undefined,
    connected,
    wrongChain: connected && walletChainId !== chainId,
    isSwitching,
    switchToLaunchpad: () => switchChain({ chainId }),
  };
}

/** Value that only updates after `delayMs` without changes (for quote inputs). */
export function useDebounced<T>(value: T, delayMs = 300): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(value), delayMs);
    return () => window.clearTimeout(id);
  }, [value, delayMs]);
  return debounced;
}

/** Wall-clock seconds, ticking every `intervalMs` (for "3m ago" labels). */
export function useNowSeconds(intervalMs = 15_000): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = window.setInterval(() => setNow(Math.floor(Date.now() / 1000)), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return now;
}

/** Launchpad-side gate for creating and buying: `canTrade(account)` and `paused()`. */
export function useTradeGate(account: Address | undefined) {
  const launchpad = launchpadConfig.isDeployed ? launchpadConfig.addresses.launchpad : undefined;
  const contract = { address: launchpad ?? zeroAddress, abi: dprkLaunchpadAbi, chainId } as const;
  const { data, error, isLoading } = useReadContracts({
    contracts: [
      { ...contract, functionName: "canTrade", args: [account ?? zeroAddress] },
      { ...contract, functionName: "paused" },
    ],
    allowFailure: false,
    query: { enabled: Boolean(launchpad), refetchInterval: 30_000, retry: retryUnlessRevert },
  });
  return {
    canTrade: account && data ? data[0] : undefined,
    paused: data?.[1],
    error,
    isLoading,
  };
}
