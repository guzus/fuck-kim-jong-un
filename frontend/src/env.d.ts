/// <reference types="vite/client" />

// Every VITE_* value is optional and arrives as a raw string (or undefined). Parse them in
// src/lib/launchpad/config.ts and src/lib/wagmi.ts; never trust them to be well-formed.
interface ImportMetaEnv {
  /** Ethereum mainnet RPC for the Lazarus Checker on `/`. */
  readonly VITE_RPC_URL?: string;
  /** Mainnet KimJongUn registry override. */
  readonly VITE_KIM_JONG_UN_ADDRESS?: string;

  /** 56 | 97 | 31337. Defaults to 56 (BNB Smart Chain). */
  readonly VITE_LAUNCHPAD_CHAIN_ID?: string;
  /** RPC override for the launchpad chain. */
  readonly VITE_LAUNCHPAD_RPC_URL?: string;
  /** KimJongUn registry on the launchpad chain. */
  readonly VITE_DPRK_KIM_JONG_UN_ADDRESS?: string;
  readonly VITE_DPRK_PASS_ADDRESS?: string;
  readonly VITE_DPRK_LAUNCHPAD_ADDRESS?: string;
  /** Lower bound for `Trade` log queries. */
  readonly VITE_DPRK_DEPLOY_BLOCK?: string;
  /** "1" registers wagmi's mock connector on anvil account #0 (local e2e only). */
  readonly VITE_E2E_MOCK_WALLET?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
