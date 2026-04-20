# DPRK.FUN: Lazarus Checker — frontend

A single-page dapp that lets anyone call `pig()` / `fuck()` on the `KimJongUn` registry contract and watch the verification stats update live. If you've done both, you're not the Lazarus Group.

- **Runtime / package manager:** Bun
- **Framework:** Vite + React 19 + TypeScript
- **On-chain client:** viem + wagmi v3 (injected connector only)
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

`netlify.toml` pins the build command (`bun run build`), publish dir (`dist`), SPA fallback (`/*` → `/index.html`), Node version, security headers, and year-long immutable cache on `/assets/*`. No dashboard tweaks required.

## Layout

```
frontend/
  netlify/functions/
    stats.mts           durable-cached /api/stats endpoint (viem multicall)
  src/
    App.tsx             composes ConnectWallet, GlobalStats, ActionCard, UserStats
    main.tsx            Vite entry — <StrictMode><App /></StrictMode>
    providers.tsx       WagmiProvider + QueryClientProvider
    index.css           Tailwind v4 + shadcn tokens + Geist font import
    components/
      action-card.tsx     pig() / fuck() write buttons with tx status + toast
      connect-wallet.tsx  Connect Wallet modal listing EIP-6963 wallets
      global-stats.tsx    reads from /api/stats via react-query
      user-stats.tsx      per-address lookup (pigCalls, fuckCalls, verified, both)
      ui/                 shadcn primitives
    lib/
      contract.ts       ABI (as const) + contract address
      wagmi.ts          createConfig(mainnet, injected) + batch.multicall
      utils.ts          shadcn cn() helper
```

Writes invalidate all react-query caches, which forces an immediate refetch of `/api/stats` and per-address reads.
