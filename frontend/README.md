# DPRK.FUN: Lazarus Checker — frontend

A single-page dapp that lets anyone call `pig()` / `fuck()` on the `KimJongUn` registry contract and watch the verification stats update live. If you've done both, you're not the Lazarus Group.

It also hosts the **DPRK.FUN Launchpad** on BNB Chain under `/launchpad` (see [Launchpad](#launchpad) below and `docs/BSC_LAUNCHPAD.md`).

- **Runtime / package manager:** Bun
- **Framework:** Vite + React 19 + TypeScript
- **On-chain client:** viem + wagmi v3 (injected connector; a mock connector only in local e2e builds)
- **UI:** Tailwind CSS v4 + shadcn/ui (base-nova preset)
- **Edge cache:** Netlify Function at `/api/stats` with durable CDN cache
- **Deploy target:** Netlify ([dprk.fun](https://dprk.fun))

Default contract: `0xF9fb0c4652A64C444EB19748935670F18560051A` (Ethereum mainnet). Default RPC: `https://eth.llamarpc.com`. Override either via env:

```
VITE_KIM_JONG_UN_ADDRESS=0x…
VITE_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/<key>
```

The same env vars are also read by the stats Netlify Function at build/runtime.

## Read path — edge-cached global stats

The three global counters (`totalVerifiedAddresses`, `totalPigCalls`, `totalFuckCalls`) are served by a Netlify Function (`netlify/functions/stats.mts`) that runs one viem `multicall` and emits:

```
cache-control: public, max-age=0, must-revalidate
netlify-cdn-cache-control: public, durable, s-maxage=15, stale-while-revalidate=60
```

Result: one RPC hit per 15s globally — every visitor reads from the durable edge cache. Clients still revalidate each time, so stats update immediately when the cache expires.

Per-address reads (the "Address lookup" card) still go through wagmi directly from the browser, since those can't be meaningfully shared across visitors.

## Launchpad

| Route | What it does |
| --- | --- |
| `/` | The Ethereum Lazarus Checker, plus a nav link and launchpad banner. |
| `/launchpad` | Pass panel (`pig()` → `fuck()` on the BSC registry → `claim()` the soulbound pass, read live from chain; the on-chain pass SVG once claimed) and the token grid (`getTokenInfos`, newest first, load more). |
| `/launchpad/create` | Pass-gated create form with UTF-8 byte limits (name 64, symbol 16, metadata 1024) and an optional initial buy quoted live with `quoteCreateBuy`. |
| `/launchpad/token/:address` | Price, market cap, BNB raised vs `graduationBnb`, buy/sell with live quotes, slippage + deadline, approve → sell, graduated state with the PancakeSwap link, best-effort recent trades. |

Routing is a ~60-line pathname router (`src/lib/router.ts`); Netlify's `/* → /index.html` rewrite serves deep links. The launchpad pages are code-split, so `/` doesn't load them.

Config is all `VITE_*` (see `.env.example`): `VITE_LAUNCHPAD_CHAIN_ID` (56, 97 or 31337), `VITE_LAUNCHPAD_RPC_URL`, `VITE_DPRK_LAUNCHPAD_ADDRESS` (the pass and registry are read from `launchpad.pass()` / `pass.kimJongUn()` when their env vars are unset), and `VITE_DPRK_DEPLOY_BLOCK`. Anything missing or malformed shows a "not deployed on this network yet" state.

Rules the launchpad code relies on:

- **Every read and write names its chain.** wagmi's default chain follows the connected wallet once the config holds more than one chain, so the checker pins `mainnet.id` and the launchpad pins `launchpadConfig.chainId`.
- **Token metadata is hostile.** It's parsed in `src/lib/launchpad/metadata.ts`: only `https:` links (`ipfs:` goes through an https gateway), no credentials in URLs, X/Telegram links must point at x.com/twitter.com and t.me, link labels come from the punycode hostname, and text loses bidi overrides and invisible characters. Nothing is rendered as HTML; images only go through `<img src>`. The CSP in `netlify.toml` blocks inline and third-party scripts on top of that.
- **Quotes are display-only.** Every trade re-quotes at submit time, derives min-out from that fresh quote (and stops if it's already worse than what was on screen by more than the slippage), sets the deadline from the later of the local clock and the latest block, simulates, and only then asks the wallet to sign.

### Local launchpad with anvil

Deploy with the contracts repo's script (`docs/BSC_LAUNCHPAD.md`), then put the printed `VITE_*` lines in `frontend/.env.local` with `VITE_LAUNCHPAD_CHAIN_ID=31337` and `VITE_LAUNCHPAD_RPC_URL=http://127.0.0.1:8545`.

For headless end-to-end tests add `VITE_E2E_MOCK_WALLET=1`. That registers wagmi's mock connector as anvil account #0 (`0xf39F…2266`); it shows up in the connect dialog as "E2E mock wallet", anvil signs its `eth_sendTransaction`s, and the connection survives reloads. It's compiled out of normal builds (the flag is inlined at build time) and refuses to turn on unless the launchpad RPC is `127.0.0.1`/`localhost`. A yellow badge marks pages where it's active.

## Develop

Vite dev (fast, no functions):

```bash
cd frontend
bun install
bun run dev   # http://localhost:5173  (/api/stats will 404 — fine, UI surfaces an error)
```

Full-stack dev with Netlify Functions:

```bash
bun run dev:netlify   # http://localhost:8888, routes /api/* to local function runner
```

Any EIP-6963-compatible wallet (MetaMask, Rabby, Rainbow, Coinbase Wallet extension, Frame, …) is picked up automatically by `injected()`.

## Build

```bash
bun run build   # → dist/
bun run preview # serve the built bundle locally
```

## Deploy to Netlify

First time:

```bash
netlify sites:create --name <your-slug> --account-slug <team>
netlify deploy --build           # draft / preview
netlify deploy --build --prod    # production
```

`netlify.toml` pins the build command (`bun run build`), publish dir (`dist`), SPA fallback (`/*` → `/index.html`), Node version, security headers on every path (CSP, frame denial, nosniff, referrer policy), and year-long immutable cache on `/assets/*`. No dashboard tweaks required.

## Layout

```
frontend/
  netlify/functions/
    stats.mts           durable-cached /api/stats endpoint (viem multicall)
  src/
    App.tsx             route switch (lazy launchpad pages) + Toaster
    main.tsx            Vite entry — <StrictMode><App /></StrictMode>
    providers.tsx       WagmiProvider + QueryClientProvider
    index.css           Tailwind v4 + shadcn tokens + Geist font import
    pages/
      home.tsx            `/`: ConnectWallet, GlobalStats, ActionCard, UserStats
      launchpad/          `/launchpad`, `/launchpad/create`, `/launchpad/token/:address`
    components/
      action-card.tsx     pig() / fuck() write buttons with tx status + toast
      connect-wallet.tsx  connect / wrong-network / disconnect for a target chain
      global-stats.tsx    reads from /api/stats via react-query
      user-stats.tsx      per-address lookup (pigCalls, fuckCalls, verified, both)
      launchpad/          pass panel, token grid, create form, trade panel, recent trades
      ui/                 shadcn primitives
    lib/
      contract.ts       KimJongUn ABI (as const) + mainnet address
      abi/launchpad.ts  generated launchpad/pass/token ABIs (script/export-abis.mjs)
      launchpad/        env config, hooks, metadata sanitizing, error copy, curve math, tx helpers
      router.ts         pathname router
      wagmi.ts          chains (mainnet + 56/97/31337), transports, connectors
      utils.ts          shadcn cn() helper
```

Writes invalidate all react-query caches, which forces an immediate refetch of `/api/stats` and per-address reads.
