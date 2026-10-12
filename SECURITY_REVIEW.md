# Tensile Contracts — Security Review Guide

> **Status:** hackathon build, **not audited**. There is no test suite yet (deliberately deferred).
> `script/DemoFlow.s.sol` is an end-to-end smoke check against a real Morpho Blue deployment. It runs flows
> F-0 to F-7 and checks that 23 attack or misuse attempts revert, each for the *intended* reason (verified by
> revert selector during development). It does **not** prove absence of bugs. Treat everything below as the
> reviewer's map.

Severity scale: **High** = loss or lock of user or lender funds is plausible · **Medium** = funds at risk under specific conditions or loss of a core guarantee · **Low** = limited impact, griefing or UX · **Info** = design notes.

---

## 1. Trust model (read first)

| Actor | Can do | If compromised |
|---|---|---|
| `ADMIN` (C-01 default admin) | Grant any role, set feeds/registries, unfreeze, recover NFTs from wrappers | **Total control.** Could grant itself `MINTER` and mint fake lots, or set a fake price feed. **Must be a Safe multisig.** |
| `RISK_ADMIN` | `adapter.setFeed`, `priceFeed.forceUpdate`, class configs, AI override at mint | **Controls the Morpho oracle price** → can trigger mass liquidations or let positions over-borrow, draining Morpho lenders. |
| `PRICE_UPDATER` (agent A-5) | Push price within ±10% per update, at most once per 10 min | Can walk the price ~±77% per hour (1.1^6). See M-02. |
| `KYC_ADMIN` | Verify/revoke wallets | Can let attackers hold lots or receive collateral; can block liquidators. |
| `INSPECTOR`, `AI_AGENT` | Attestations | Inspection/AI review are conditions for minting; a malicious inspector plus a colluding warehouse can mint against non-existent steel. |
| Warehouse operator + reserve signers | Custody/release confirmations, 2-of-2 reserve reports | Off-chain fraud (release without burn, fake reserves). The chain detects inconsistencies; it cannot see steel. |
| `CreditRouter` (C-15) | Owner of **every** Morpho position | A router bug affects all loans. No admin withdraw paths exist. Keep it that way. |
| `TensileCreditVault` (C-14b) | Holder of lender USDC and Morpho supply shares across every active lot market | A vault bug affects every lender in that stablecoin. Loss socialisation is global in v1. |

The **physical/legal layer is out of scope for code review**, but it is the dominant risk. The contracts' job is to make on-chain double-pledging and double-spending impossible, and to turn off-chain inconsistencies into on-chain freezes.

---

## 2. Issues found and FIXED during the build (verify the fixes)

| ID | Issue | Fix | Where |
|---|---|---|---|
| F-01 | `borrowMore` was allowed at a warehouse frozen by a dispute while reserves still looked healthy. | `ReserveGuard.isHealthy/canAdd` return `false` for frozen warehouses; `poke` no-ops when already frozen. | `ReserveGuard.sol` |
| F-02 | A compromised admin could point the router at a fake "marketplace" and call `payoffFor` to take lots worth more than their debt. | `CreditRouter.setMarketplace` is **set-once**. | `CreditRouter.sol` |
| F-03 | The price deviation bound was per update, so the agent could chain updates in one block and move the price anywhere. | `minUpdateInterval` (10 min) between agent updates. | `TensilePriceFeed.sol` |
| F-04 | Router bypass: a liquidator holding seized wrapper tokens could `supplyCollateral` on Morpho directly and borrow up to the LLTV, skipping reserve, freeze and attestation checks. | Wrapper rejects any transfer **to Morpho** unless `from == router`. Registry router is set-once. | `LotWrapper.sol`, `MarketRegistry.sol` |
| F-05 | Griefing: any lot holder could request redemption, never send a collector, then dispute and auto-freeze the whole warehouse. | `raiseDispute` only flags + emits; humans decide on a freeze. `RedemptionManager` no longer holds `GUARDIAN`. | `RedemptionManager.sol` |
| F-06 | A zero oracle price would let liquidators seize collateral for (near) nothing. | `TensileMorphoOracle.price()` reverts on 0. | `TensileMorphoOracle.sol` |
| F-07 | Partial repayment by asset amount could over- or under-withdraw from the vault vs. Morpho's share rounding. | Repay-by-shares inside `_repayFromPayer`, then `withdrawFor(type(uint256).max)` which withdraws by shares. Any dust stays on the vault as interest. | `CreditRouter.sol` |

---

## 3. Open findings

### High

**H-01 — Centralised control of the Morpho oracle.** `RISK_ADMIN` can swap the price feed (`adapter.setFeed`) or `forceUpdate` it instantly. Morpho lenders rely entirely on that price. *Recommendation:* Safe multisig for `RISK_ADMIN`, a timelock on `setFeed`/`forceUpdate` (P2), and monitoring alerts on `FeedSet` and `AnswerUpdated`.

**H-02 — ADMIN can mint arbitrary lots.** Granting `MINTER` to any address bypasses C-07 entirely. Inherent to the role model. *Recommendation:* Safe multisig plus a timelock on `grantRole` for contract roles (e.g. wrap C-01 behind an OZ `TimelockController`).

**H-04 — RISK_ADMIN can mass-liquidate via regional haircut.** `PriceOracleAdapter.setHaircut` has no rate limit and feeds the Morpho oracle through `pricePerTonne`. Raising a region's haircut from 5 % to 20 % drops that region's collateral value ~15.8 % instantly, which could push open loans into Morpho liquidation territory in one tx. The 10 %/update bound on `TensilePriceFeed` does not apply. *Recommendation:* cap the max haircut change per day (e.g. 200 bps) and / or route `setHaircut` through a timelock. Same reasoning applies to `setMaxPriceStaleness`.

**H-05 — Vault supplies to any market whose class RISK_ADMIN approved.** If a RISK_ADMIN enables a class with a bad oracle or lax `routerMaxLtvBps`, the vault's lenders are exposed to that class up to its cap. *Recommendation:* every new class config and every change to an existing one goes through the propose/approve flow (C-12) with a timelock, and `vault.setClassCap` is a separate signal that the risk team has reviewed the class.

**H-03 — Off-chain custody fraud.** A warehouse plus inspector colluding (or with compromised reserve signer keys) can mint against steel that does not exist, or keep reporting reserves after a release without a burn. *Mitigations outside code:* liable bonded warehouses, rotating inspectors, insurance. *Mitigation in code (P2):* stake and slashing (C-04/C-22).

### Medium

**M-01 — Stale price pauses liquidations.** The oracle reverts when the price is older than `maxPriceStaleness` (default 3 days). Morpho then cannot liquidate, so bad debt can build up during an outage. Reverting is still safer than returning a stale or zero price. *Recommendation:* keep the A-5 heartbeat well under the staleness window, and alert on staleness.

**M-02 — Bounded price walking.** Even after F-03, `PRICE_UPDATER` can move the price ~10% every 10 min. *Recommendation:* add a cumulative per-day cap (e.g. a ±15% band around a daily anchor) before mainnet.

**M-03 — KYC-gated liquidations shrink the liquidator set.** Seized collateral can only go to verified accounts. If no verified liquidator is active, bad debt grows. *Recommendation:* run and fund keeper A-6 from a verified address, and onboard several liquidators.

**M-04 — Partial liquidation splits title.** After a partial liquidation, wrapper tokens sit with several holders. Only a holder of 100% of the supply can `unwrap`, so the physical lot can't be redeemed or sold through `payoffFor` (blocked with `PartiallyLiquidated`) until someone consolidates. *Recommendation (P1/P2):* a consolidation auction, or a buy-out right for the largest holder.

**M-05 — Frozen warehouse blocks loan exit.** `closeLoan` and `payoffFor` unwrap the NFT, and `MaterialPassport._update` blocks transfers at frozen warehouses, so both revert while frozen. Borrowers can still `repay` (stopping interest) but cannot recover the lot until unfreeze. This is intended, but it needs to be communicated to users.

**M-06 — Stale listings and blanket approvals.** If a seller used `setApprovalForAll(marketplace)`, an old listing (possibly from when the lot was encumbered) stays executable at the old price after circumstances change. *Recommendation:* UI should auto-cancel listings on ownership/loan changes, and encourage per-token `approve`. Consider listing nonces per token (P1).

**M-07 — No emergency pause.** There is no global pause on C-15/C-16/C-14b. The only circuit breaker is per-warehouse freeze. *Recommendation:* add `Pausable` to router (new loans), marketplace and vault (new deposits) before mainnet.

**M-08 — Vault accrual is partial.** `_accrueAll` iterates at most `accrueBatchSize` (default 20) tracked markets before a share-price op. If the vault is in more active markets than that, a new depositor can time entry just before `onRepay` on an unaccrued market and dilute existing lenders by a sliver. *Recommendation:* make keeper A-6 call `sweep(start, count)` across all active markets at least once per block in which a deposit or withdraw lands, and raise `accrueBatchSize` toward Morpho's gas limit.

**M-09 — Loss socialisation.** `onLoss` debits all lenders. A single bad class drags the share price for everyone. *Recommendation:* per-class caps (now in place via `setClassCap`) must be set defensively; a junior/senior tranche split is on the roadmap.

**M-10 — Idle vault cash earns nothing.** USDC not currently out as loans sits idle. Lenders accept lower blended yield in exchange for withdrawability. *Recommendation:* park idle cash in a vanilla Aave/Morpho USDC market in v2.

**M-11 — First-depositor inflation.** Mitigated by OZ v5 ERC-4626 virtual-shares offset. *Recommendation:* seed the vault with a tiny deployer deposit at deploy, so an attacker can't be first.

### Low

- **L-01** Mint fee is taken at `requestMint` and not refunded on reject/cancel/expiry (`MintingController`).
- **L-02** Inspectors and AI agents are not bound to specific warehouses, and attestation order (inspection vs custody) is not enforced. Any `INSPECTOR` can `REINSPECTION` any lot and refresh `lastAttestedAt`.
- **L-03** `ReserveGuard.poke` freezes a warehouse with a stale feed even if it has zero outstanding lots (harmless but noisy).
- **L-04** `TensileReserveFeed` only *emits* `LargeDrop`; the guard reacts only when reserve < outstanding.
- **L-05** `PriceIndex` (C-19) can be wash-traded between two verified accounts (min 1 t). It is informational. **Do not feed it into the oracle** without manipulation resistance.
- **L-06** A revoked or expired identity can still *send* lots and wrapper tokens (only recipients are checked). This is intentional, so users are never trapped.
- **L-07** `LotWrapper.recover` lets ADMIN send an accidentally-transferred NFT to any address (trust).
- **L-08** Rounding: `borrowMore`/`availableToBorrow` use `value * collateral / fullSupply` (floor), and the marketplace's `pricePerTonne` is floored. All are conservative, but please confirm.
- **L-09** `ensureLotMarket` is permissionless. Anyone can pay gas (~1.3M) to deploy a wrapper and market for any lot in an enabled class. That's harmless, but it means class parameters are frozen per lot at creation.

### Informational

- **I-01** Morpho's `SafeTransferLib` wraps our custom errors from `LotWrapper` into `"transfer reverted"` / `"transferFrom reverted"`. The frontend should pre-check KYC and router rules for clear messages.
- **I-02** Compiler: `auto_detect_solc` picked **0.8.37** for our `^0.8.24` files (Morpho is pinned to 0.8.19). Pin a version for audit reproducibility.
- **I-03** One Morpho market per lot fragments lender liquidity. Aggregation via a Morpho Vault curated by Tensile is P1/P2 (no contract changes needed here).
- **I-04** USDC is assumed to be worth $1 inside the Morpho oracle. The de-peg guard (`requireStablePeg`) only blocks *new* borrowing in C-15.
- **I-05** Only standard ERC-20 stablecoins are supported (no fee-on-transfer or rebasing tokens).
- **I-06** Morpho is not deployed on Monad testnet. `Deploy.s.sol` self-deploys Morpho Blue + AdaptiveCurveIrm (GPL-2.0) there. On mainnet, use and **verify** the official addresses, `isIrmEnabled`, and `isLltvEnabled(0.77e18)`.

---

## 4. Where to focus review time

1. **`CreditRouter`** — share/asset accounting against Morpho (`_owedAssets` → `toAssetsUp`, repay by shares), the `borrowerOf` lifecycle, `_release` for full vs partial collateral, the `_repayFromPayer` sequence (repay-by-shares first, then withdraw-all from vault), `_reportLossIfAny`, and reentrancy across Router ↔ Vault ↔ Marketplace ↔ Morpho ↔ Wrapper ↔ Passport.
2. **`TensileCreditVault`** — `_accrueAll` correctness (does it ever miss accrual before a share-price op?), class-cap math, principal vs interest split in `onRepay`, dust after withdraw-by-shares, loss debit against `totalSuppliedAssets`.
3. **`Marketplace._settle`** — `price - fee - payoff` arithmetic, approval reset, plain vs encumbered branch selection, bid escrow accounting (`cancelBid` / `acceptBid`).
4. **`MaterialPassport._update`** — every path that moves a lot (mint, transfer, wrap, unwrap, burn) and every state the gate must block.
5. **`LotWrapper._update`** — KYC gate plus the Morpho-only-from-router rule. Make sure no flow legitimately needs another sender into Morpho.
6. **Role wiring** in `script/TensileDeployer.sol` — least privilege, and nothing granted that isn't needed.
7. **Oracle scaling** — `TensileMorphoOracle.scale = 10^(loanDecimals + 7)` with an 18-decimal wrapper. Re-derive it independently.
8. **Reserve feed signatures** — EIP-712 domain (chainId plus contract address), replay protection via monotonic `observedAt`, and signer rotation.

---

## 5. Invariants for the future test suite

1. For every warehouse `w`: Σ `quantityKg` of live (unburned) tokens at `w` == `passport.outstandingKg(w)`.
2. A lot in `REDEEMING`, or at a frozen warehouse, never changes owner.
3. `router.borrowerOf(id) != 0` ⇒ the lot NFT is owned by its wrapper **or** the router position was liquidated (collateral < fullSupply).
4. For every wrapper: `wrapped == true` ⇔ the wrapper owns the NFT and `totalSupply == fullSupply`.
5. Wrapper tokens only ever enter Morpho from the router.
6. A `certHash` is minted at most once, ever.
7. No mint succeeds when the reserve is stale, when reserve < outstanding + qty, or when the warehouse is frozen.
8. Marketplace USDC balance == Σ active bid amounts (no residue after any settle).
9. After `buy`: buyer owns the lot; seller + fee collector + Morpho received exactly `price`.
10. The router holds no USDC and no wrapper tokens between transactions.
11. Vault: `totalAssets == cash + totalSuppliedAssets` (losses are already debited from `totalSuppliedAssets`).
12. Vault: for every active market, Σ `suppliedForMarket[id]` where lot's class key is k == `suppliedForClass[k]`.
13. Vault: `suppliedForMarket[id] <= classCap[classKey]`.
14. Vault: `maxWithdraw(user) <= cash` always.
15. After a successful close, vault's Morpho supply shares for that market are 0 OR `suppliedForMarket[id] == 0`.

---

## 6. Pre-mainnet checklist

- [ ] All admin roles on a Safe; deployer `ADMIN` revoked.
- [ ] Timelock on `grantRole`, `adapter.setFeed`, `forceUpdate`, `registry.setClass`.
- [ ] Pause added to C-15 / C-16 / C-14b (M-07).
- [ ] Keeper A-6 sweeping C-14b accrual (M-08).
- [ ] Daily haircut-change cap or timelock on `setHaircut` (H-04).
- [ ] Daily price-move cap (M-02).
- [ ] Official Morpho Blue + IRM addresses verified on Monad; LLTV enabled.
- [ ] Chainlink USDC/USD feed wired into `adapter.setStableGuard`.
- [ ] Foundry unit, fuzz and invariant suites (section 5) passing.
- [ ] External audit.
