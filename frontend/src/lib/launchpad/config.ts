import { defineChain, getAddress, isAddress, zeroAddress, type Address, type Chain } from "viem";
import { anvil, bsc, bscTestnet } from "viem/chains";

// Launchpad runtime config, parsed once from VITE_* env vars. Nothing here throws: a bad or missing
// value turns into a `problems` entry and the UI shows a "not deployed on this network" state.

export const LAUNCHPAD_CHAIN_IDS = [56, 97, 31337] as const;
export type LaunchpadChainId = (typeof LAUNCHPAD_CHAIN_IDS)[number];

/** Anvil's first dev account. Anvil signs eth_sendTransaction for it, which is what the e2e mock wallet relies on. */
export const ANVIL_ACCOUNT_0: Address = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

/**
 * Public RPCs per chain, used for reads when VITE_LAUNCHPAD_RPC_URL is unset (in order, via a fallback
 * transport). On 56, publicnode goes first because bsc-dataseed rejects eth_getLogs outright (-32005, even
 * for 1,000 blocks of one address), which cost the recent-trades scan a failed round-trip per chunk;
 * publicnode serves ranges up to 10k blocks. bsc-dataseed stays as the fallback.
 */
const PUBLIC_RPCS: Record<LaunchpadChainId, readonly [string, ...string[]]> = {
  56: ["https://bsc-rpc.publicnode.com", "https://bsc-dataseed.bnbchain.org"],
  97: ["https://data-seed-prebsc-1-s1.bnbchain.org:8545", "https://bsc-testnet-rpc.publicnode.com"],
  31337: ["http://127.0.0.1:8545"],
};

const env = import.meta.env;
const problems: string[] = [];

function clean(raw: string | undefined): string | undefined {
  const value = raw?.trim();
  return value ? value : undefined;
}

export function isLocalRpcUrl(url: string): boolean {
  try {
    const { hostname } = new URL(url);
    return hostname === "127.0.0.1" || hostname === "localhost" || hostname === "[::1]";
  } catch {
    return false;
  }
}

function readChainId(): LaunchpadChainId | undefined {
  const raw = clean(env.VITE_LAUNCHPAD_CHAIN_ID);
  if (!raw) return 56;
  const id = Number(raw);
  const supported = LAUNCHPAD_CHAIN_IDS.find((x) => x === id);
  if (supported === undefined) {
    // Don't silently fall back to 56: addresses meant for another chain must never be used on BSC.
    problems.push(`VITE_LAUNCHPAD_CHAIN_ID="${raw}" is not supported (use 56, 97 or 31337).`);
    return undefined;
  }
  return supported;
}

function readRpcUrl(): string | undefined {
  const raw = clean(env.VITE_LAUNCHPAD_RPC_URL);
  if (!raw) return undefined;
  try {
    const { protocol } = new URL(raw);
    if (protocol === "https:" || protocol === "http:") return raw;
  } catch {
    // fall through
  }
  problems.push(`VITE_LAUNCHPAD_RPC_URL is not an http(s) URL; using the public RPC instead.`);
  return undefined;
}

function readAddress(name: string, raw: string | undefined): Address | undefined {
  const value = clean(raw);
  if (!value) return undefined;
  if (!isAddress(value, { strict: false })) {
    problems.push(`${name} is not a valid address.`);
    return undefined;
  }
  const address = getAddress(value);
  return address === zeroAddress ? undefined : address;
}

function readBlock(raw: string | undefined): bigint | undefined {
  const value = clean(raw);
  if (!value) return undefined;
  if (!/^\d{1,15}$/.test(value)) {
    problems.push(`VITE_DPRK_DEPLOY_BLOCK must be a block number.`);
    return undefined;
  }
  return BigInt(value);
}

const selectedChainId = readChainId();
const rpcOverride = readRpcUrl();

/**
 * Chain objects for the three launchpad networks. `rpcUrls.default` is what a wallet gets offered in
 * wallet_addEthereumChain and what wagmi's mock connector sends transactions to, so it only carries the
 * env override when that override is local (a hosted RPC URL may embed an API key that shouldn't end up
 * in users' wallets).
 */
function buildChain(id: LaunchpadChainId): Chain {
  const override = id === selectedChainId ? rpcOverride : undefined;
  const walletRpc =
    override && (id === 31337 || isLocalRpcUrl(override)) ? override : PUBLIC_RPCS[id][0];
  if (id === 56 || id === 97) {
    // A local node posing as BSC may be a bare `anvil --chain-id 56` with no Multicall3 at the canonical
    // address. Local reads are cheap, so drop multicall batching there rather than depend on it (a fork of
    // BSC has Multicall3 either way).
    const local = override !== undefined && isLocalRpcUrl(override);
    return defineChain({
      ...(id === 56 ? bsc : bscTestnet),
      rpcUrls: { default: { http: [walletRpc] } },
      ...(local ? { contracts: {} } : {}),
    });
  }
  // Local anvil stands in for BSC, so label its native currency BNB. viem's anvil chain has no
  // multicall3 entry, which is what keeps batched reads from targeting a contract that isn't there.
  return defineChain({
    ...anvil,
    name: "Anvil (local)",
    nativeCurrency: { name: "BNB", symbol: "BNB", decimals: 18 },
    rpcUrls: { default: { http: [walletRpc] } },
  });
}

export const launchpadChains: Record<LaunchpadChainId, Chain> = {
  56: buildChain(56),
  97: buildChain(97),
  31337: buildChain(31337),
};

/** RPC URLs wagmi uses for reads on a launchpad chain (env override first, otherwise public fallbacks). */
export function launchpadReadRpcUrls(id: LaunchpadChainId): readonly string[] {
  if (id === selectedChainId && rpcOverride) return [rpcOverride];
  return PUBLIC_RPCS[id];
}

const addresses = {
  kimJongUn: readAddress("VITE_DPRK_KIM_JONG_UN_ADDRESS", env.VITE_DPRK_KIM_JONG_UN_ADDRESS),
  pass: readAddress("VITE_DPRK_PASS_ADDRESS", env.VITE_DPRK_PASS_ADDRESS),
  launchpad: readAddress("VITE_DPRK_LAUNCHPAD_ADDRESS", env.VITE_DPRK_LAUNCHPAD_ADDRESS),
};

const chain = launchpadChains[selectedChainId ?? 56];
const walletRpcUrl = chain.rpcUrls.default.http[0];

// Env-gated only: the flag is inlined at build time, so a normal build compiles this to `false` and the
// mock connector is tree-shaken. It additionally refuses to turn on unless transactions would go to a
// local node, since only a local dev node signs for anvil's well-known account.
const e2eRequested = env.VITE_E2E_MOCK_WALLET === "1";
const e2eMockWallet = e2eRequested && selectedChainId !== undefined && isLocalRpcUrl(walletRpcUrl);
if (e2eRequested && !e2eMockWallet) {
  problems.push("VITE_E2E_MOCK_WALLET=1 was ignored: it needs a local launchpad RPC (127.0.0.1 or localhost).");
}

export const launchpadConfig = {
  /** The configured launchpad chain. When VITE_LAUNCHPAD_CHAIN_ID is invalid this is BSC, for display only. */
  chain,
  chainId: chain.id as LaunchpadChainId,
  chainValid: selectedChainId !== undefined,
  nativeSymbol: chain.nativeCurrency.symbol,
  addresses,
  deployBlock: readBlock(env.VITE_DPRK_DEPLOY_BLOCK),
  /** True when the launchpad address is configured for a supported chain. Pass/registry can be derived on-chain. */
  isDeployed: selectedChainId !== undefined && addresses.launchpad !== undefined,
  e2eMockWallet,
  problems: problems as readonly string[],
} as const;

if (problems.length > 0 && typeof console !== "undefined") {
  console.warn(`[dprk.fun] launchpad config: ${problems.join(" ")}`);
}

export function chainLabel(c: Pick<Chain, "id" | "name">): string {
  if (c.id === 1) return "Ethereum";
  if (c.id === 56) return "BNB Chain";
  if (c.id === 97) return "BSC Testnet";
  if (c.id === 31337) return "Anvil";
  return c.name;
}

export function explorerUrl(kind: "tx" | "address" | "token", value: string): string | undefined {
  const base = chain.blockExplorers?.default.url;
  return base ? `${base}/${kind}/${value}` : undefined;
}

/** PancakeSwap swap link for a graduated token. Local chains have no PancakeSwap UI. */
export function pancakeSwapUrl(token: Address): string | undefined {
  if (chain.id === 56) return `https://pancakeswap.finance/swap?chain=bsc&outputCurrency=${token}`;
  if (chain.id === 97) return `https://pancakeswap.finance/swap?chain=bscTestnet&outputCurrency=${token}`;
  return undefined;
}

const MOCK_FLAG_KEY = "dprk.e2e.mockWalletConnected";

/** E2E only: whether the mock wallet was connected before the last reload (so tests survive page.goto). */
export function readMockWalletFlag(): boolean {
  try {
    return window.localStorage.getItem(MOCK_FLAG_KEY) === "1";
  } catch {
    return false;
  }
}

export function writeMockWalletFlag(connected: boolean): void {
  try {
    if (connected) window.localStorage.setItem(MOCK_FLAG_KEY, "1");
    else window.localStorage.removeItem(MOCK_FLAG_KEY);
  } catch {
    // storage unavailable: the mock wallet just won't auto-reconnect
  }
}
