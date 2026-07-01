# STOEX Smart Contracts Overview

This document introduces each core contract for the **multi-asset, multi-provider** STOEX stack.

## System Architecture

- `TradeManager` — central orchestrator; all trade calls include `assetId` + `providerId`.
- `AssetLedger` — soulbound certificates (one per user per asset) and per-provider inventory accounting.
- `AssetRegistry` — catalog of tradeable assets (`GOLD`, `SILVER`, …).
- `AssetProviderRegistry` — provider entities, supported assets, operators, sell/redeem routing.
- `WhitelistRegistry` — KYC / wallet eligibility.
- `GovernanceConfig` — per-asset caps, approval policies, TTL.
- `EscrowVault` — scoped locks per `(user, assetId, providerId)`.
- `TimelockController` — wallet / lot timelocks.

**Units:** integer micrograms (µg). `1 gram = 1_000_000 µg`.

---

## Asset and provider IDs

On-chain identifiers are `bytes32` values: `keccak256("GOLD")`, `keccak256("SILVER")`, `keccak256("AP1")`, etc. See `src/libraries/StoexIds.sol`.

---

## `TradeManager`

### Key write endpoints

| Flow | Signature |
|------|-----------|
| Buy | `createBuyRequestFor(user, assetId, providerId, weightUg, fiat, paymentRef, txDetailsHash)` |
| Sell | `createSellRequestFor(user, assetId, providerId, amountUg, payoutRefId)` |
| Redeem | `createRedeemRequestFor(user, assetId, providerId, amountUg, deliveryRefId)` |
| Mint | `proposeMintFor(ap, assetId, providerId, amountUg, vaultReceiptId, lot)` |
| Burn | `proposeBurnFor(ap, assetId, providerId, amountUg, referenceId, reason)` |

Buy auto-executes; other flows use propose → approve → `executeRequest`.

`TradeRequest` includes `assetId` and `providerId`.

**Removed:** `setRoutingAddresses` — routing lives in `AssetProviderRegistry`.

---

## `AssetLedger`

- `userHolding(user, assetId, providerId)` — µg balance for that provider slice.
- `userActiveProvider(user, assetId)` — binding constraint (one provider per asset at a time).
- `providerPoolBalance(assetId, providerId)` — unsold AP pool for that slice.
- `totalSupply(assetId)`, `circulatingSupply(assetId)`.
- `tokenIdByBeneficiary(user, assetId)` — certificate per asset.

---

## `AssetRegistry`

- `registerAsset(assetId, symbol, name, precision)`
- `isActive(assetId)`, `getAsset(assetId)`

---

## `AssetProviderRegistry`

- `registerProvider(providerId, name)`
- `updateProviderName(providerId, name)` — admin can change display name anytime (`providerId` bytes32 slug is immutable)
- `setProviderAsset(providerId, assetId, supported)`
- `setAssetRouting(providerId, assetId, sellPayout, redeemSink)`
- `addProviderOperator(providerId, wallet)`
- `isOperator(providerId, wallet)`, `getSellPayout`, `getRedeemSink`

---

## `GovernanceConfig`

Per-asset caps via `dailyBuyCap(assetId)`, `dailySellCap(assetId)`, `minimumBuyValueInUg(assetId)`.

`setDailyCapForAsset(assetId, requestType, cap)` for AT role.

---

## `EscrowVault`

- `lockTokens(wallet, assetId, providerId, amountUg, reason, requestId)`
- `getAvailableBalance(wallet, assetId, providerId)`

---

## Deployment env (new)

| Variable | Purpose |
|----------|---------|
| `ASSET_REGISTRY` | AssetRegistry proxy |
| `ASSET_PROVIDER_REGISTRY` | AssetProviderRegistry proxy |
| `ASSET_LEDGER` | AssetLedger proxy (replaces `GOLD_NFT`) |
| `DEFAULT_PROVIDER_LABEL` | e.g. `AP1` → `keccak256("AP1")` |
| `ASSET_LABEL` / `PROVIDER_LABEL` | Used in flow scripts |

Fresh proxy deploy required; no in-place storage migration.
