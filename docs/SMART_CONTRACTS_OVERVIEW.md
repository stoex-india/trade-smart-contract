# STOEX smart contracts overview (auditor / integrator guide)

**Version:** V1 simplified trade model  
**Solidity:** `^0.8.24`  
**Pattern:** UUPS upgradeable proxies, AccessControl, optional ERC-2771 gasless (`*For` + trusted forwarder)

This document describes the **on-chain design** for estimation and review. Deployment addresses are omitted — use `src/` and `abi/`.

---

## 1. General

| Item | Detail |
|------|--------|
| Domain | Multi-asset (GOLD / SILVER), multi-provider tokenization |
| Unit | Integer **micrograms (µg)**; `1 g = 1_000_000` µg |
| Human roles | **`DEFAULT_ADMIN_ROLE`** and **`USER_ROLE` only** on trade / policy paths |
| System role | `TRADE_MANAGER_ROLE` on `AssetLedger` (contract-to-contract) |
| Gasless | `TradeManager`, `WhitelistRegistry`, `AssetLedger` via trusted forwarder |
| Paid admin | `executeRequest`, registry admin, governance, timelock, escrow admin |

**V1 removes:** on-chain mint/burn into a provider pool, multi-party approval (AP / VP / PAP / AT), and pool inventory gates on buy.

---

## 2. Contracts under review

| Contract | Path | Role |
|----------|------|------|
| `TradeManager` | `src/TradeManager.sol` | Orchestrates buy / sell / redeem |
| `AssetLedger` | `src/AssetLedger.sol` | Holdings, certificates, circulating + lifetime volume |
| `AssetRegistry` | `src/AssetRegistry.sol` | Asset catalog |
| `AssetProviderRegistry` | `src/AssetProviderRegistry.sol` | Providers, operators, sell/redeem routing |
| `WhitelistRegistry` | `src/WhitelistRegistry.sol` | KYC / eligibility / wallet change |
| `GovernanceConfig` | `src/GovernanceConfig.sol` | Caps, mins, TTL (admin-only) |
| `EscrowVault` | `src/EscrowVault.sol` | Logical locks for sell/redeem |
| `TimelockController` | `src/TimelockController.sol` | Wallet/lot lock gates (admin-only) |
| Libs / bases | `src/libraries/*`, `src/base/*` | Types, roles, relayer gate, admin bootstrap |

---

## 3. Architecture

```
                    Trusted forwarder (Tresori)
                              │
         ┌────────────────────┼────────────────────┐
         ▼                    ▼                    ▼
  WhitelistRegistry     TradeManager          AssetLedger
         │                    │                    │
         │                    ├── EscrowVault      │
         │                    ├── TimelockController
         │                    ├── GovernanceConfig
         │                    ├── AssetRegistry
         │                    └── AssetProviderRegistry
         └────────────────────┘
```

---

## 4. Identifiers & enums

- **assetId / providerId:** `bytes32` = `keccak256(label)` e.g. `"GOLD"`, `"AP1"`
- **RequestType (active):** `Buy`, `Sell`, `Redeem` (`Mint` / `Burn` enum values may remain for layout/history but have no entrypoints)
- **RequestStatus (active path):** `Proposed` → `Executed` | `Rejected` | `Cancelled` | `Expired`  
  Intermediate approval statuses are unused in V1.
- **EscrowReason:** `Sell`, `Redeem`

---

## 5. Roles

| Role | Used for |
|------|----------|
| `DEFAULT_ADMIN_ROLE` | Execute sell/redeem, reject, pause, upgrades, all governance, timelock set/override, provider registry, wallet-change approval, unsuspend |
| `USER_ROLE` | Create buy/sell/redeem / cancel (via relayer); granted on register |
| `TRADE_MANAGER_ROLE` | Ledger mutators callable only by `TradeManager` |

Legacy role constants (`AP_ROLE`, `VP_ROLE`, `AT_ROLE`, `PAP_ROLE`, `AUDITOR_ROLE`) may still exist in `StoexRoles.sol` but are **not required** for V1 trade flows.

---

## 6. Auth & upgrade

- Admin lifecycle: deployer → `setInitialAdmin` → `transferAdmin`
- Gasless: `onlyTrustedForwarder` on `*For` entrypoints; actor address is first argument
- UUPS: `_authorizeUpgrade` gated by admin
- Pause on `TradeManager` / `AssetLedger` where applicable
- Reentrancy guards on state-changing trade/ledger paths

---

## 7. Contract summaries

### 7.1 `TradeManager`

**Buy** — `createBuyRequestFor` auto-finalizes (no admin).  
**Sell / Redeem** — create with escrow → admin `executeRequest(requestId, settlementRefId)`.

| Function | Notes |
|----------|-------|
| `createBuyRequestFor(user, assetId, providerId, weightUg, fiat, paymentRef, txHash)` | Instant; `paymentRef` = SHA-256 commitment |
| `createSellRequestFor(user, assetId, providerId, amountUg)` | No settlement ref at create |
| `createRedeemRequestFor(user, assetId, providerId, amountUg)` | No settlement ref at create |
| `executeRequest(requestId, settlementRefId)` | Admin; requires non-zero ref; status must be `Proposed` |
| `rejectRequest(requestId, reason)` | Admin; unlocks escrow |
| `cancelRequestFor(initiator, requestId)` | User; unlocks escrow |
| `expireRequest(requestId)` | After TTL; unlocks escrow |

Settlement refs are stored in `TradeRequest.paymentRefId` (buy at create; sell/redeem at execute).

### 7.2 `AssetLedger`

Soulbound ERC-721 certificate: one token per `(user, asset)` on first buy (or admin `mintCertificate`).

**Accounting (V1):**

| Mapping / view | Meaning |
|----------------|---------|
| `userHolding[user][asset][provider]` | User balance |
| `circulatingSupply(asset, provider)` | Outstanding with users |
| `totalCirculating(asset)` | Sum across providers |
| `lifetimeIssued` | Cumulative buys |
| `lifetimeSoldBack` | Cumulative sells |
| `lifetimeRedeemed` | Cumulative redeems |

**Invariant:**  
`circulating = lifetimeIssued − lifetimeSoldBack − lifetimeRedeemed`

**Mutators (TradeManager only):** `creditUserBuy`, `decreaseSupply`, `mintCertificateForTrade`.

No provider pool inventory; buys do not require on-chain stock.

### 7.3 `GovernanceConfig`

Admin-only caps: daily buy/sell, min buy, min redeem, max per tx, request expiry, default timelock duration, non-KYC fiat cap, precision.  
No approval policy matrices in V1.

### 7.4 `EscrowVault`

Logical lock keyed by `requestId`. Available balance = holding − locked. Only TradeManager locks/unlocks/releases.

### 7.5 `TimelockController`

Admin sets wallet/lot locks; sell/redeem create reverts while locked. Mint-lot auto-apply removed with mint.

### 7.6 `AssetProviderRegistry`

Providers, supported assets, operators (ops metadata), `sellPayout` / `redeemSink` addresses used when releasing escrow (events / off-chain routing — not token transfers of gold).

### 7.7 `WhitelistRegistry`

Register / KYC / suspend / blacklist. Wallet change: **admin-only** single approval. `unsuspendWallet`: admin.

---

## 8. Major flows

### 8.1 Onboarding

```
registerUserFor / adminRegisterUser
  → USER_ROLE on whitelist + TradeManager
verifyKYCFor  → isEligible (sell/redeem)
```

Pending KYC may buy under `nonKycMaxBuyFiatAmount`.

### 8.2 Buy

```
createBuyRequestFor (gasless)
  → eligibility / caps / provider binding
  → mint cert if needed
  → creditUserBuy (holding↑, circulating↑, lifetimeIssued↑)
  → status Executed
```

### 8.3 Sell

```
createSellRequestFor (gasless) → escrow lock, Proposed
  → admin executeRequest(id, settlementRefHash)
       → releaseEscrow → decreaseSupply(Sell)
       → circulating↓, lifetimeSoldBack↑
```

### 8.4 Redeem

```
createRedeemRequestFor (gasless) → escrow, Proposed
  → admin executeRequest(id, settlementRefHash)
       → decreaseSupply(Redeem)
       → circulating↓, lifetimeRedeemed↑
```

Min amount: `minRedeemAmountUg`.

### 8.5 Reject / cancel / expire

Unlock escrow; terminal status. No third-party rejectors.

### 8.6 Provider lifecycle

Admin: `registerProvider`, `setProviderAsset`, `setAssetRouting`, `addProviderOperator`.  
Operators are **not** required for trade approvals (there are none).

---

## 9. Settlement references

| Flow | When written | Content |
|------|--------------|---------|
| Buy | Create | SHA-256(secret ‖ payment plaintext) |
| Sell | Execute | SHA-256(secret ‖ payout plaintext) |
| Redeem | Execute | SHA-256(secret ‖ delivery plaintext) |

Hashing is **off-chain**. Contracts store `bytes32` only. Secret must never be on-chain.

---

## 10. Accounting sketch

| Event | Holding | Circulating | Lifetime |
|-------|---------|-------------|----------|
| Buy | ↑ | ↑ | issued ↑ |
| Sell (execute) | ↓ | ↓ | soldBack ↑ |
| Redeem (execute) | ↓ | ↓ | redeemed ↑ |

Escrow locks do not change holding until execute/reject/cancel/expire.

---

## 11. Suggested audit focus

1. Admin concentration on execute / reject / governance / timelock  
2. Circulating vs holding consistency under escrow + concurrent requests  
3. Provider binding and switch-after-full-exit  
4. Non-KYC buy fiat accrual vs verified buy caps  
5. Relayer / EIP-2771 actor spoofing on `*For`  
6. Soulbound certificate + nominee transfer  
7. UUPS / storage layout (legacy unused slots retained)  
8. Settlement ref is commitment-only (no on-chain verify of plaintext)

---

## 12. Known V1 product trade-offs

- **No on-chain inventory gate** — overselling vs physical vault is an off-chain / ops risk  
- **Admin is sole settler** for sell/redeem — trust and key security critical  
- **Refs are one-way hashes** — recovery of plaintext needs off-chain systems  
- **Legacy Mint/Burn/approval enums/slots** may remain for upgrade layout; no live entrypoints  

---

## 13. Glossary

| Term | Meaning |
|------|---------|
| Circulating | µg credited to users and not yet sold back or redeemed |
| Lifetime issued | Cumulative buy volume per (asset, provider) |
| Settlement ref | SHA-256 commitment of off-chain payment/payout/delivery id |
| Escrow | Logical lock reducing available balance until settle/unlock |
