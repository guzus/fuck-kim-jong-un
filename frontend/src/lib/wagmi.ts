import { createConfig, http } from "wagmi";
import { mainnet } from "wagmi/chains";
import { injected } from "wagmi/connectors";

const rpcUrl =
  (import.meta.env.VITE_RPC_URL as string | undefined) ?? "https://eth.llamarpc.com";

export const wagmiConfig = createConfig({
  chains: [mainnet],
  connectors: [injected({ shimDisconnect: true })],
  transports: {
    [mainnet.id]: http(rpcUrl, { batch: { wait: 16 } }),
  },
  batch: { multicall: { wait: 16 } },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
