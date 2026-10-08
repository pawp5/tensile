# Tensile — Smart Contracts

On-chain infrastructure for industrial materials: verified lots of steel become **Material Passports** (ERC-721).
They can be borrowed against using **existing Morpho Blue liquidity**, sold with atomic Delivery-versus-Payment,
and redeemed for the physical goods. A Proof-of-Reserve circuit-breaker freezes any warehouse whose reserves stop
covering its tokens.

> ⚠️ Hackathon build — **not audited**. Read [`SECURITY_REVIEW.md`](./SECURITY_REVIEW.md) before reviewing or deploying.

---

## What changed vs. the Build Guide v0.1

We **tap into Morpho Blue** instead of running our own lending pool.

| v0.1 | Now | Why |
|---|---|---|
| C-13 InterestRateModel | **Removed**. Morpho's AdaptiveCurveIrm sets rates | No custom rate code to get wrong |
| C-14 LendingPool (ERC-4626) | **TensileCreditVault** — ERC-4626 USDC vault that aggregates lender liquidity and supplies it just-in-time to any lot's Morpho market the router opens | One deposit covers every lot; no fragmented liquidity |
| C-17 AuctionHouse | **Removed**. Liquidations happen natively on Morpho | Battle-tested liquidation engine |
| C-12 RiskParams | **MarketRegistry** — class risk config + per-lot Morpho market creation | |
| C-13 | **TensileMorphoOracle** — Morpho `IOracle` per class | |
| C-14 | **LotWrapper** — ERC-20 per lot (Morpho needs ERC-20 collateral) | |
| C-15 LoanManager | **CreditRouter** — wraps, posts collateral, borrows, repays, pays off on sale | |
| LOCKED token state | **Gone**. A pledged lot sits inside its wrapper, so the owner simply doesn't hold it | Simpler state machine |
| C-04 staking, C-20 Reputation, all P2 | Not built (roadmap) | Deadline scope |

**Design in one line:** each lot gets its own ERC-20 wrapper (1e18 units = 1 kg) and its own isolated Morpho market.
The **CreditRouter owns every Morpho position** and records the real borrower, so users never grant Morpho
authorisations and nobody can bypass Tensile's checks. Wrapper tokens can only enter Morpho through the router.

---

## Contracts

| ID | Contract | Path | Purpose |
|---|---|---|---|
| C-01 | `TensileAccessManager` | `src/access/` | Central role registry (OZ AccessControl) |
| C-02 | `IdentityRegistry` | `src/identity/` | KYC allow-list + protocol-contract whitelist |
| C-03 | `WarehouseRegistry` | `src/asset/` | Warehouses: operator, region, reserve feed, frozen flag |
| C-05 | `AttestationRegistry` | `src/asset/` | Append-only evidence log (custody, inspection, AI review, release) |
| C-06 | `MaterialPassport` | `src/asset/` | ERC-721 lot token; transfer gate; outstanding kg per warehouse |
| C-07 | `MintingController` | `src/asset/` | request → AI review → inspection → custody → reserve check → mint |
| C-08 | `RedemptionManager` | `src/asset/` | "No burn, no release": request → warehouse release → burn |
| C-09 | `TensileReserveFeed` | `src/reserve/` | Per-warehouse PoR feed, Chainlink `AggregatorV3` compatible, 2-of-2 signed |
| C-10 | `ReserveGuard` | `src/reserve/` | reserve ≥ outstanding && fresh && not frozen; `poke` freezes |
| C-11a | `TensilePriceFeed` | `src/pricing/` | USD/t per (material, region); bounded agent updates |
| C-11b | `PriceOracleAdapter` | `src/pricing/` | The only lot-valuation code; haircuts; stablecoin de-peg guard |
| C-12 | `MarketRegistry` | `src/credit/` | Class risk config; deploys lot wrapper + Morpho market |
| C-13 | `TensileMorphoOracle` | `src/credit/` | Morpho `IOracle` (price scaled 1e36) |
| C-14a | `LotWrapper` | `src/credit/` | ERC-20 for one lot; KYC-gated; Morpho deposits only via router |
| C-14b | `TensileCreditVault` | `src/credit/` | ERC-4626 USDC vault; lenders deposit once; supplies JIT to lot markets; interest and losses accrue to shares |
| C-15 | `CreditRouter` | `src/credit/` | openLoan / borrowMore / repay / closeLoan / payoffFor |
| C-16 | `Marketplace` | `src/market/` | Listings, private OTC, RFQ bids, atomic DvP incl. loan payoff |
| C-18 | `FeeCollector` | `src/market/` | Fee sink + accounting events |
| C-19 | `PriceIndex` | `src/market/` | Trade-based last price + VWAP per (material, region) |
| C-24 | `MockUSDC` | `src/mocks/` | Testnet only |

> `TensileCreditVault` is wired to the router (`router.setVault`), has `FEE_NOTIFIER` for its reserve-factor fee, is whitelisted as a protocol contract on `IdentityRegistry`, and needs a `RISK_ADMIN`-set per-class cap before any supply can flow to that class.

Interfaces for every contract are in `src/interfaces/`. Build against these — M3 (frontend/indexer) and M4 (agents).

---

## Quick start

```bash
# install Foundry: https://getfoundry.sh
./setup.sh                        # forge-std, OpenZeppelin v5.1.0, morpho-blue, morpho-blue-irm + build
forge script script/DemoFlow.s.sol -vv   # full local simulation of flows F-0 … F-7 (no broadcast)
```

Expected tail of the demo:

```
F-7 liquidation on Morpho
  [blocked as expected] non-KYC liquidator
  [blocked as expected] bypass router: deposit seized collateral on Morpho
  ...
ALL FLOWS PASSED
```

### Deploy

```bash
cp .env.example .env    # fill PRIVATE_KEY etc.
source .env

# Monad testnet: leave USDC and MORPHO empty -> deploys MockUSDC + our own Morpho Blue/IRM
forge script script/Deploy.s.sol --rpc-url monad_testnet --broadcast
# writes deployments/<chainId>.json

# Onboard a warehouse + material class (reserve feed, price feed, Morpho oracle, class config)
forge script script/Onboard.s.sol --rpc-url monad_testnet --broadcast
```

On **Monad mainnet**, set `USDC`, `MORPHO` and `IRM` to the official addresses and confirm `isLltvEnabled(LLTV)` first.
Both scripts were broadcast end-to-end against a local Anvil node.

---

## Flows → functions (cross-reference with the Build Guide)

| Flow | Who | Calls |
|---|---|---|
| F-0 Onboarding | Admin | `Onboard.s.sol`; `IdentityRegistry.setIdentity` (KYC_ADMIN) |
| F-1 Tokenize | Owner → AI → Inspector → Warehouse → anyone | `MintingController.requestMint` → `AttestationRegistry.attest(AI_REVIEW)` → `attest(INSPECTION)` → `MintingController.confirmCustody` → `TensileReserveFeed.submit` → `MintingController.finalizeMint` |
| F-2 Lend | Lender | `TensileCreditVault.deposit(assets, lender)` (one-time; covers every lot in enabled classes) |
| F-2 Borrow | Owner | `MaterialPassport.approve(router, id)` → `CreditRouter.openLoan(id, amount)` |
| F-3 Sell (plain / encumbered) | Seller, buyer | `Marketplace.list` → `Marketplace.buy` (auto `payoffFor` if encumbered) |
| F-3b RFQ | Buyer, seller | `Marketplace.placeBid` → `acceptBid` / `cancelBid` |
| F-4 Continuous proof | A-3, inspectors | `TensileReserveFeed.submit` + `ReserveGuard.poke`; `attest(REINSPECTION)` |
| F-5 Redeem | Holder → warehouse | `RedemptionManager.requestRedemption(id, keccak256(secret))` → `confirmRelease` |
| F-6 Breach | Anyone / A-3 | `ReserveGuard.poke(wid)` → frozen; `WarehouseRegistry.unfreeze` (ADMIN) |
| F-7 Liquidation | Keeper A-6 (KYC'd) | `IMorpho.liquidate(params, router, seized, 0, "")`; borrower `CreditRouter.closeLoan` |

### Notes for M3 (frontend / indexer)
- Index these events: `LotMinted`, `LotStateChanged`, `LotBurned`, `MintRequested`, `CustodyConfirmed`, `MintFinalized`, `Attested`, `AnswerUpdated` (both feeds), `WarehouseFrozen`/`Unfrozen`, `ReserveBreach`, `LotMarketCreated`, `LoanOpened`, `Repaid`, `LoanClosed`, `PaidOffBySale`, `Listed`, `BidPlaced`, `Settled`, `RedemptionRequested`, `Redeemed`, `RedemptionDisputed`, `TradeRecorded`, plus Morpho `Supply`/`Borrow`/`Liquidate` for lot markets.
- A lot is **encumbered** when `passport.ownerOf(id) == registry.wrapperOf(id)` and `router.borrowerOf(id) != 0`.
- Health factor: read Morpho position of `router` in `registry.marketIdOf(id)`, and price from `TensileMorphoOracle.price()`.
- Morpho wraps our custom errors as `"transfer reverted"`. Pre-check KYC (`identity.isVerified`) and show clear messages.

### Notes for M4 (agents)
- **A-1 / A-2:** `AttestationRegistry.attest(AI_REVIEW, REQUEST, requestId, score, keccak256(report), "ipfs://…")` with the `AI_AGENT` role. Score ≥ `minAiScore` (70) is required to finalize, unless RISK_ADMIN overrides.
- **A-3:** compute `TensileReserveFeed.reportDigest(reserveKg, observedAt)` and get both EIP-712 signatures (warehouse + inspector signer keys). Then call `submit(...)` and immediately `ReserveGuard.poke(wid)`.
- **A-4:** `MarketRegistry.proposeClass(...)` (AI_AGENT) → RISK_ADMIN `approveClass`.
- **A-5:** `TensilePriceFeed.update(price)` (PRICE_UPDATER). Max ±10% per update, minimum 10 min apart.
- **A-6:** watch Morpho positions owned by the router; `IMorpho.liquidate` from a **KYC-verified** funded wallet.
- **A-7:** read-only plus unsigned calldata for the user's wallet. Never holds user keys.

---

## Roles

| Role | Holder | Granted in |
|---|---|---|
| `ADMIN` | Safe multisig | constructor |
| `KYC_ADMIN`, `RISK_ADMIN` | Ops (Safe signers) | manual |
| `INSPECTOR` | Inspection firms | manual |
| `AI_AGENT`, `PRICE_UPDATER` | Agent wallets (one key per agent) | manual |
| `MINTER` | C-07 | `TensileDeployer` |
| `REDEEMER` | C-08 | `TensileDeployer` |
| `RECORDER` | C-07, C-08 | `TensileDeployer` |
| `GUARDIAN` | C-10 | `TensileDeployer` |
| `REGISTRAR` | C-12 | `TensileDeployer` |
| `FEE_NOTIFIER` | C-07, C-15, C-16 | `TensileDeployer` |
| `INDEX_RECORDER` | C-16 | `TensileDeployer` |

## Units

kg are integers · stablecoin uses token decimals (USDC 6) · prices are USD per tonne with 8 decimals · ratios in bps · wrapper: 1e18 = 1 kg · Morpho oracle scale 1e36.

## Licensing

Files that import Morpho Blue libraries (`CreditRouter`, `MarketRegistry`, `TensileMorphoOracle`, interfaces/scripts using them) are **GPL-2.0-or-later**, matching Morpho Blue. Other files are MIT.
