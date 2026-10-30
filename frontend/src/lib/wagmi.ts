import type { Chain } from "viem";
import { createConfig, fallback, http, injected, mock, type CreateConnectorFn, type Transport } from "wagmi";
import { mainnet } from "wagmi/chains";

import {
  ANVIL_ACCOUNT_0,
  LAUNCHPAD_CHAIN_IDS,
  launchpadChains,
  launchpadConfig,
  launchpadReadRpcUrls,
  readMockWalletFlag,
  type LaunchpadChainId,
} from "@/lib/launchpad/config";

// `||` so an empty `VITE_RPC_URL=` (as in .env.example) still means "use the default".
const rpcUrl = import.meta.env.VITE_RPC_URL?.trim() || "https://eth.llamarpc.com";

// With more than one chain configured, wagmi's `state.chainId` follows the connected wallet (and is
// persisted), so any read or write without an explicit `chainId` can land on BSC. Every call site pins
// its chain: the Lazarus Checker uses `mainnet.id`, the launchpad uses `launchpadConfig.chainId`.

const launchpadChainList = LAUNCHPAD_CHAIN_IDS.map((id) => launchpadChains[id]);

// E2E mock wallet. The raw env comparison is kept at the use site so a normal build folds it to `false`
// and drops the mock connector entirely; launchpadConfig.e2eMockWallet adds the local-RPC check.
const e2eMockWallet = import.meta.env.VITE_E2E_MOCK_WALLET === "1" && launchpadConfig.e2eMockWallet;

// The mock connector starts on chains[0], so in e2e mode the launchpad chain goes first. Nothing reads
// the default chain anyway (see above), so the order changes nothing else.
const chains: readonly [Chain, ...Chain[]] = e2eMockWallet
  ? [launchpadConfig.chain, mainnet, ...launchpadChainList.filter((c) => c.id !== launchpadConfig.chainId)]
  : [mainnet, ...launchpadChainList];

function launchpadTransport(id: LaunchpadChainId): Transport {
  const [first, ...rest] = launchpadReadRpcUrls(id);
  if (rest.length === 0) return http(first);
  return fallback([http(first), ...rest.map((url) => http(url))]);
}

const transports: Record<number, Transport> = {
  [mainnet.id]: http(rpcUrl, { batch: { wait: 16 } }),
  56: launchpadTransport(56),
  97: launchpadTransport(97),
  31337: launchpadTransport(31337),
};

const connectors: CreateConnectorFn[] = [injected({ shimDisconnect: true })];
if (e2eMockWallet) {
  connectors.push(
    mock({
      accounts: [ANVIL_ACCOUNT_0],
      // reconnect + defaultConnected (from localStorage) lets a connected test survive page reloads.
      features: { reconnect: true, defaultConnected: readMockWalletFlag() },
    }),
  );
}

export const wagmiConfig = createConfig({
  chains,
  connectors,
  transports,
  batch: { multicall: { wait: 16 } },
  // BSC makes a block every ~0.75 s; the 4 s default would leave trades "pending" long after they land.
  // Mainnet keeps the default.
  pollingInterval: { 56: 1_000, 97: 1_000, 31337: 500 },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
