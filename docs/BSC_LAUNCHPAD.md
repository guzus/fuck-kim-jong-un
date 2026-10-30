# DPRK.FUN Launchpad on BNB Chain — spec

> Status: in development on `feat/bsc-launchpad`. The contracts are unaudited. Do not deploy them to mainnet with
> real funds until the checklist at the end is done.

## Product

The pitch: a Lazarus-proof memecoin launchpad on BNB Chain. No DPRK operator will publicly insult the Supreme Leader, so
anyone who does is certified as "not Lazarus".

1. **Insult Kim.** Call `pig()` and `fuck()` on the `KimJongUn` registry, the same immutable contract as
   `src/KimJongUn.sol` (a fresh deployment on BSC).
2. **Claim the pass.** `DprkPass.claim()` mints a soulbound ERC-721, the *Not-Lazarus Pass* ("김정은 개새끼" pass). It
   only works once `hasPiggedAndFuckedKimJongUn(msg.sender)` is true. There is one pass per address and it can't be
   transferred.
3. **Use the launchpad.** Only pass holders can create tokens or buy from a bonding curve. Anyone can sell back to a
   curve, and selling is never paused.
4. **Graduate.** When a curve sells its whole `CURVE_SUPPLY`, the same transaction seeds a PancakeSwap V2 pair with all
   real BNB plus `LP_SUPPLY` tokens and burns the LP tokens to `0x000000000000000000000000000000000000dEaD`.

## Contracts (`src/launchpad/`)

| File | Role |
| --- | --- |
| `interfaces/IDprkPass.sol` | Pass interface (ERC-721 metadata + ERC-5192). **Source of truth.** |
| `interfaces/IDprkLaunchpad.sol` | Launchpad interface, structs, events, and errors. **Source of truth.** |
| `interfaces/IDprkToken.sol` | Launch token interface. **Source of truth.** |
| `DprkPass.sol` | `is ERC721, IDprkPass`. On-chain SVG `tokenURI`. Soulbound. |
| `DprkLaunchpad.sol` | `is IDprkLaunchpad`, plus `Ownable2Step` and a reentrancy guard. Holds every curve. |
| `DprkToken.sol` | `is ERC20, IDprkToken`. Deployed by the launchpad, which receives the full supply. |
| `interfaces/IPancakeV2.sol` | Minimal factory, pair, and WBNB interfaces. |

Changing an interface means changing the frontend too. Regenerate ABIs with `forge build && node script/export-abis.mjs`
(it writes `frontend/src/lib/abi/launchpad.ts`).

### Economics (defaults)

- `TOTAL_SUPPLY = 1_000_000_000e18`, `CURVE_SUPPLY = 800_000_000e18`, `LP_SUPPLY = 200_000_000e18`.
- Virtual constant product `x·y = k`, starting at
  `initialVirtualTokenReserve = CURVE_SUPPLY² / (CURVE_SUPPLY − LP_SUPPLY)` and
  `initialVirtualBnbReserve = V0`, an immutable constructor argument.
- That choice of virtual token reserve makes the PancakeSwap listing price exactly equal the curve's final spot
  price, so there is no graduation arbitrage. Real BNB raised at sell-out is `graduationBnb = V0·(S−L)/L = 3·V0`.
  - Chain 56: `V0 = 8 BNB`, which graduates at 24 BNB (≈120 BNB FDV at listing).
  - Chain 97: `V0 = 0.5 tBNB`, which graduates at 1.5 tBNB.
  - Chain 31337: `V0 = 1 ether`.
- Fee: `feeBps` is immutable and capped at 500 (default 100 = 1%). The buy fee is taken from gross input before the
  curve; the sell fee is taken from gross output. Fees accrue in `accruedFees`, separate from curve reserves, and
  `claimFees()` pays them to `feeRecipient`.
- Rounding always favours the pool. Curve output rounds down. A completing buy's required input rounds up.
- Completing buy: when an input would buy at least the remaining `realTokenReserve`, the buyer gets exactly the
  remainder. They pay `ceil` of the BNB needed (gross of fee) and get the rest refunded in the same tx. The curve
  then graduates in that same tx.

### Gate

- `createToken` and `buy` revert with `NotCertified(msg.sender)` unless `pass.isCertified(msg.sender)`.
- `createToken` and `buy` revert with `LaunchpadPaused()` while the owner has paused. `sell` and graduation are
  never paused.
- `DprkToken` transfer rule before graduation: a transfer is allowed iff it is a mint, OR `from == launchpad`, OR
  `to == launchpad`, OR `pass.isCertified(to)`. Uncertified wallets and the PancakeSwap pair therefore can't receive
  curve tokens. That blocks pre-seeding the pair, which is how router-based launchpads get griefed. After
  `markGraduated()` the token is a plain ERC-20.

### Graduation (inline, in the completing buy)

```
graduated = true
pair = factory.getPair(token, WBNB); if zero, factory.createPair(token, WBNB)
token.markGraduated()
WBNB.deposit{value: realBnbReserve}; WBNB.transfer(pair, realBnbReserve)
token.transfer(pair, LP_SUPPLY)
liquidity = pair.mint(DEAD)
```

Graduation deliberately bypasses the router. Someone can pre-create the pair, donate WBNB, and `sync()` so reserves
read `(0, x)`. That makes `router.addLiquidityETH` revert in `quote()`. A direct `mint` still succeeds, because
`amount = balance − reserve` ignores the donated WBNB. Required tests: pair pre-created, WBNB donated plus `sync`,
then graduation succeeds and the pool price stays at or above the curve price.

### Invariants (fuzz/invariant tests must cover)

- `address(launchpad).balance >= Σ realBnbReserve + accruedFees`.
- For every curve: `virtualTokenReserve − realTokenReserve == initialVirtualTokenReserve − CURVE_SUPPLY`. Also
  `virtualBnbReserve − realBnbReserve == initialVirtualBnbReserve`, and `k` never decreases.
- A sell can always be paid: `quoteSell` gross output ≤ `realBnbReserve` for any amount ≤ circulating curve tokens.
- A buy-then-sell round trip never returns more BNB than was put in.
- Launchpad token balance ≥ `realTokenReserve + LP_SUPPLY` before graduation.

### Verified BSC addresses (checked on-chain 2026-10-30)

| Chain | PancakeSwap V2 factory | WBNB |
| --- | --- | --- |
| 56 (mainnet) | `0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73` | `0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c` |
| 97 (testnet) | `0x6725F303b657a9451d8BA641348b6761A6CC7a17` | `0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd` |

(Routers `0x10ED43C718714eb63d5aA57B78B54704E256024E` (56) and `0xD99D1c33F9fC3444f8101754aBC46c52416550D1` (97) report
these factories and WBNB. They're used only for the frontend's "Trade on PancakeSwap" links.)

### Deployment script (`script/DeployDprkFun.s.sol`)

- Env: `KIM_JONG_UN_ADDRESS` (optional; reuse an existing registry, otherwise deploy one), `FEE_RECIPIENT` (default:
  deployer), `FEE_BPS` (default 100), `INITIAL_VIRTUAL_BNB` (default per chain, as above), `PASS_NAME`,
  `PASS_SYMBOL`.
- Chains 56 and 97 use the addresses above. Any other chain (local anvil) deploys `MockWBNB` and a minimal
  PancakeSwap-V2-compatible mock factory/pair.
- Writes `deployments/<chainId>.json`:
  `{ chainId, kimJongUn, pass, launchpad, pancakeFactory, wbnb, deployBlock }`.
- Prints the matching `VITE_*` lines for the frontend.

## Frontend (`frontend/`, dprk.fun)

The existing Ethereum-mainnet Lazarus Checker on `/` keeps working unchanged. Every existing mainnet read and write
stays pinned to `chainId: mainnet.id`. The launchpad lives under `/launchpad`, on the chain from
`VITE_LAUNCHPAD_CHAIN_ID`.

| Route | Content |
| --- | --- |
| `/` | Existing checker, plus a nav link and banner for the launchpad. |
| `/launchpad` | Pass progress (pig → fuck → claim, read from chain), the pass SVG once claimed, and a token grid (newest first: name, symbol, image, progress bar, market cap in BNB, graduated badge) with a "Launch a token" CTA. |
| `/launchpad/create` | Gated create form: name, symbol, description, image URL, website/X/Telegram, optional initial buy with live `quoteCreateBuy`. |
| `/launchpad/token/:address` | Token page: metadata, price, market cap, progress to graduation, BNB raised / `graduationBnb`, buy/sell panel (quotes, slippage, deadline, approve → sell), graduated state with PancakeSwap link, recent trades (best-effort `Trade` logs). |

Env (all optional; when they're missing, the UI shows "launchpad not deployed on this network" instead of crashing):

```dotenv
VITE_LAUNCHPAD_CHAIN_ID=56            # 56 | 97 | 31337
VITE_LAUNCHPAD_RPC_URL=               # RPC override for that chain
VITE_DPRK_KIM_JONG_UN_ADDRESS=        # KimJongUn registry on the launchpad chain
VITE_DPRK_PASS_ADDRESS=
VITE_DPRK_LAUNCHPAD_ADDRESS=
VITE_DPRK_DEPLOY_BLOCK=               # lower bound for Trade log queries
VITE_E2E_MOCK_WALLET=                 # "1" = wagmi mock connector on anvil account #0 (dev/e2e only)
```

Token metadata is the `metadata` string: JSON with optional `description`, `image`, `website`, `twitter`, and
`telegram`, at most 1024 bytes. The contract enforces length only. Name is 1–64 bytes, symbol is 1–16 bytes. The UI
must treat metadata as hostile: parse defensively, allow only `https:`/`ipfs:` URLs, and never inject HTML. The pass
`tokenURI` is a base64 JSON data URI whose `image` is a base64 SVG; render it only through `<img src>`.

## Local development

```sh
anvil                                   # or: anvil --fork-url https://bsc-dataseed.bnbchain.org (real PancakeSwap, chain 56)
forge script script/DeployDprkFun.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key #0>
node script/export-abis.mjs
cd frontend && cp .env.example .env.local   # fill in the VITE_* lines printed by the deploy script
bun install && bun run dev
```

## Mainnet checklist

- [ ] Independent audit of `DprkPass`, `DprkToken`, and `DprkLaunchpad`.
- [ ] `forge test` including invariant runs, plus the BSC fork test (`BSC_RPC_URL=… forge test --match-path test/launchpad/*Fork*`).
- [ ] Testnet (97) dry run of the full flow, including graduation on PancakeSwap testnet.
- [ ] Multisig as owner and fee recipient. Verify the contracts on BscScan.
- [ ] Legal review: memecoin launchpad, sanctions/geofencing, terms.
