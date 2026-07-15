# STOEX Smart Contracts — Auditor Overview

Guide for smart-contract auditors. Describes architecture, contracts, roles, major business flows, and security-relevant design. **No deployment addresses** — review against `src/` and ABIs under `abi/`.

| Item | Detail |
|------|--------|
| Solidity | `^0.8.24` |
| Upgrade pattern | UUPS proxies (`ERC1967` + OpenZeppelin `UUPSUpgradeable`) |
| Access control | OpenZeppelin `AccessControlUpgradeable` + one-time `setInitialAdmin` / `transferAdmin` |
| Unit of account | Integer **micrograms (µg)** — `1 gram = 1_000_000` µg |
| Domain | Multi-asset, multi-provider digital precious-metal inventory & trade orchestration (India STOEX stack) |

---

## 1. Scope — contracts under review

| Contract | Path | Role |
|----------|------|------|
| `TradeManager` | `src/TradeManager.sol` | Central orchestrator for buy / sell / redeem / mint / burn requests |
| `TradeManagerLib` | `src/libraries/TradeManagerLib.sol` | External library for execution / co-sign verification (bytecode size split) |
| `AssetLedger` | `src/AssetLedger.sol` | Soulbound certificates + inventory / holdings accounting |
| `AssetRegistry` | `src/AssetRegistry.sol` | Asset catalog (`GOLD`, `SILVER`, …) |
| `AssetProviderRegistry` | `src/AssetProviderRegistry.sol` | Providers, operators, sell/redeem routing |
| `WhitelistRegistry` | `src/WhitelistRegistry.sol` | User onboarding, KYC, eligibility, wallet changes |
| `GovernanceConfig` | `src/GovernanceConfig.sol` | Caps, approval policies, TTL, optional VP flag |
| `EscrowVault` | `src/EscrowVault.sol` | Locks user metal for sell / redeem until execute or reject |
| `TimelockController` | `src/TimelockController.sol` | Wallet / mint-lot timelocks |
| Shared libs | `src/libraries/StoexTypes.sol`, `StoexRoles.sol`, `StoexIds.sol` | Enums, structs, role constants, canonical IDs |
| Bases | `src/base/StoexDeployerAdminUpgradeable.sol`, `StoexRelayerGate.sol` | Admin bootstrap + trusted-forwarder gate |

**Interfaces:** `src/interfaces/*`  
**Tests:** `test/` (Foundry)

Out of scope for runtime semantics but relevant to ops: Foundry deploy/upgrade scripts under `script/`.

---

## 2. System architecture

```
                    ┌─────────────────────┐
                    │  Trusted Forwarder  │  (EIP-2771 relayer — gasless *For APIs)
                    └──────────┬──────────┘
                               │
         ┌─────────────────────▼─────────────────────┐
         │               TradeManager                 │
         │  create* / propose* / approve / execute    │
         └─┬───────┬────────┬────────┬────────┬──────┘
           │       │        │        │        │
           ▼       ▼        ▼        ▼        ▼
     AssetLedger  Escrow  Whitelist  AssetReg  ProviderReg
           │      Vault   Registry   istry     + routing
           │
           ▼
     TimelockController
           ▲
           │
     GovernanceConfig  (policies read by TradeManager)
```

**Design principles:**

- Every trade call is scoped by **`assetId`** + **`providerId`** (`bytes32`, typically `keccak256("LABEL")`).
- Users are bound to **one active provider per asset** while they hold a non-zero balance for that asset.
- Buy **auto-executes** in the create tx; sell / redeem / mint / burn are **request → approvals → execute**.
- Fiat / bank settlement is **off-chain**; contracts store references (`paymentRef`, `payoutRefId`, `deliveryRefId`) and optional `fiatValue` / `txDetailsHash`.
- Sell / redeem **escrow** user holdings until execute or reject/cancel.

---

## 3. Identifiers & domain model

### IDs

| ID | Type | How formed |
|----|------|------------|
| `assetId` | `bytes32` | e.g. `keccak256("GOLD")`, `keccak256("SILVER")` |
| `providerId` | `bytes32` | Slug hash e.g. `keccak256("AP1")` — **immutable**; display name is separate |
| `userId` | `bytes32` | App-defined id at registration |
| Amounts | `uint256` | Always µg |

Helpers / seeded IDs: `src/libraries/StoexIds.sol`.

### Core enums (`StoexTypes`)

| Enum | Values |
|------|--------|
| `RequestType` | Buy, Sell, Redeem, Mint, Burn |
| `RequestStatus` | Proposed → APApproved / VPApproved / PAPApproved → ATApproved → Executed / Rejected / Expired / Cancelled |
| `KYCStatus` | Pending, Verified, Rejected |
| `EscrowReason` | Sell, Redeem |

### Roles (`StoexRoles`)

| Role | Typical use |
|------|-------------|
| `DEFAULT_ADMIN_ROLE` | Admin bootstrap, upgrades, execute sell/redeem/mint/burn, provider ops, pause, etc. |
| `USER_ROLE` | Granted via whitelist onboarding; required for buy/sell/redeem |
| `AP_ROLE` | Asset Provider — mint/burn propose, sell/redeem AP approval step; must also be provider **operator** |
| `VP_ROLE` | Vault Provider — optional in mint/burn/redeem policies |
| `AT_ROLE` | Authorized Trader / compliance — policy updates, final approval steps |
| `PAP_ROLE` | Physical Asset Provider — redeem approval chain |
| `AUDITOR_ROLE` | Read / auditor RBAC (if used by ops) |
| `TRADE_MANAGER_ROLE` | Granted **to TradeManager proxy** on AssetLedger / EscrowVault so it may mutate inventory & escrow |

---

## 4. Auth & upgrade patterns (audit-sensitive)

### Admin lifecycle

`StoexDeployerAdminUpgradeable`:

1. Deployer set at `initialize`.
2. Deployer calls **`setInitialAdmin` once** → grants `DEFAULT_ADMIN_ROLE`.
3. Current admin may **`transferAdmin`** (grant new, revoke self).

### Gasless / EIP-2771

`StoexRelayerGate`:

- Contracts with a trusted forwarder expose `*For(address actor, …)` entrypoints.
- Only `msg.sender == trustedForwarder()` may call those functions.
- Actor identity is the **first argument** (and must match signed meta-tx intent off-chain).

**ERC-2771 aware contracts:** `TradeManager`, `WhitelistRegistry`, `AssetLedger`.  
**Not forwarder-gated (admin direct tx):** `AssetProviderRegistry`, `AssetRegistry`, `GovernanceConfig`, `EscrowVault` admin setters, `TimelockController` admin setters, `TradeManager.executeRequest`.

### Upgradeability

- All major contracts are **UUPS**; `_authorizeUpgrade` restricted to `DEFAULT_ADMIN_ROLE`.
- Review storage gaps, library linking (`TradeManager` + `TradeManagerLib`), and initializer guards.

### Pausing / reentrancy

- `TradeManager` / `AssetLedger`: `PausableUpgradeable` + `ReentrancyGuardUpgradeable` on critical paths.

---

## 5. Contract-by-contract summary

### 5.1 `TradeManager`

**Responsibility:** Single entry for trade lifecycle and approvals.

**Gasless writes (`onlyTrustedForwarder`):**

| Function | Purpose |
|----------|---------|
| `createBuyRequestFor(user, assetId, providerId, weightUg, fiat, paymentRef, txDetailsHash)` | Buy — validates + **auto-executes** |
| `createSellRequestFor(user, assetId, providerId, amountUg, payoutRefId)` | Sell — escrow lock, create request |
| `createRedeemRequestFor(user, assetId, providerId, amountUg, deliveryRefId)` | Redeem — escrow lock, create request |
| `proposeMintFor(ap, assetId, providerId, amountUg, vaultReceiptId, lot)` | AP proposes mint into provider pool |
| `proposeBurnFor(ap, assetId, providerId, amountUg, referenceId, reason)` | AP proposes burn from provider pool |
| `approveRequestFor(approver, requestId)` | Next policy role approves |
| `rejectRequestFor(rejector, requestId, reason)` | Reject + unlock escrow if locked |
| `cancelRequestFor(initiator, requestId)` | Initiator cancel + unlock if needed |

**Admin / other:**

| Function | Access |
|----------|--------|
| `executeRequest(requestId)` | `DEFAULT_ADMIN_ROLE` — settles sell/redeem/mint/burn (not buy) |
| `executeWithCoSignatures(...)` | EIP-712 batch co-sign path as alternative to stepwise approve |
| `setTrustedForwarder` | Admin |
| `grantUserRoleFromRegistry` | Callable by WhitelistRegistry during onboard |
| Pause | Admin (via Pausable) |

**Key invariants to review:**

- Buy: eligibility (KYC or non-KYC + fiat cap), pool inventory, provider binding, min amount / daily buy cap.
- Sell / redeem: KYC required, provider binding, timelock, escrow then release on execute.
- Mint / burn: `AP_ROLE` + `AssetProviderRegistry.isOperator(providerId, ap)`.
- Approve steps follow `GovernanceConfig.getApprovalPolicy(requestType)` in order; AP steps also require operator for that request’s `providerId`.
- Status must reach `ATApproved` before `executeRequest` (status name reused as “fully approved”).

Execution logic lives largely in **`TradeManagerLib.executeTrade`**.

---

### 5.2 `AssetLedger`

**Responsibility:** Accounting + soulbound certificate (one token per user per asset).

| Area | Functions / behavior |
|------|----------------------|
| Holdings | `userHolding(user, assetId, providerId)`, `userActiveProvider(user, assetId)` |
| Pool | `providerPoolBalance(assetId, providerId)`, `mintToPool`, `burnFromPool`, buy/sell/redeem supply mutators |
| Certificates | `mintCertificate` / `mintCertificateForTrade` — soulbound (transfers blocked) |
| Auth | Mutators typically `TRADE_MANAGER_ROLE` or `AP_ROLE` as designed |

**Invariants:** circulating / total supply consistency; pool cannot go negative; binding conflict if user tries another provider while holding.

---

### 5.3 `AssetRegistry`

| Function | Access |
|----------|--------|
| `registerAsset(assetId, symbol, name, precision)` | Admin |
| `setAssetActive(assetId, active)` | Admin |
| `isActive` / `getAsset` | View |

TradeManager rejects inactive assets.

---

### 5.4 `AssetProviderRegistry`

| Function | Access |
|----------|--------|
| `registerProvider(providerId, name)` | Admin |
| `updateProviderName(providerId, name)` | Admin (slug/`providerId` immutable) |
| `setProviderActive` | Admin |
| `setProviderAsset(providerId, assetId, supported)` | Admin |
| `setAssetRouting(providerId, assetId, sellPayout, redeemSink)` | Admin — **non-zero** addresses required |
| `addProviderOperator` / `removeProviderOperator` | Admin — wallet maps to **at most one** provider |
| Views | `isOperator`, `getSellPayout`, `getRedeemSink`, `providerSupportsAsset`, `getOperators` |

**Execute effects:**

- Sell → escrow released to **`sellPayout`**.
- Redeem → escrow released to **`redeemSink`**.

No trusted forwarder — admin operations are paid / direct signed txs.

---

### 5.5 `WhitelistRegistry`

| Function | Access |
|----------|--------|
| `registerUserFor(wallet, userId, kycRef)` | Trusted forwarder — creates profile, notifies TradeManager for `USER_ROLE` |
| `verifyKYCFor(user)` | Trusted forwarder — user self-verify path after off-chain KYC |
| Wallet change request / approve | Forwarder / rules as coded |
| `setWalletRisk`, `setUserBlocked`, `rejectKYC` | Admin |
| Views | `isEligible`, `isEligibleForNonKycUser`, `hasUserRole`, `getProfile` |

**Eligibility:**

- **Buy:** KYC verified **or** non-KYC eligible under fiat cap (`GovernanceConfig.nonKycMaxBuyFiatAmount`).
- **Sell / redeem:** `isEligible` (KYC verified) required.

---

### 5.6 `GovernanceConfig`

| Capability | Notes |
|------------|-------|
| Per-asset daily buy/sell caps | AT-configurable |
| `minimumBuyValueInUg(assetId)` | Admin |
| `maxAmountPerTx`, `minRedeemAmountUg`, `requestExpiryDuration`, `defaultTimelockDuration` | AT |
| `setApprovalPolicy(requestType, roles[])` | AT — ordered role list for approve steps |
| `setVpRequiredForApprovals(bool)` | Admin — when `false`, **strips `VP_ROLE`** from Mint/Burn/Redeem policies in `getApprovalPolicy` |
| Non-KYC max fiat | AT |

**Default approval policies (as seeded; VP may be stripped):**

| Request | Default roles (then optional VP strip) |
|---------|----------------------------------------|
| Buy | *(empty — auto-executes)* |
| Sell | AP → AT |
| Redeem | AP → VP → PAP → AT *(VP omitted if flag false)* |
| Mint | VP → AT *(VP omitted if flag false → AT only)* |
| Burn | VP → AT *(same)* |

Auditors should treat policy as **mutable** post-deploy via AT.

---

### 5.7 `EscrowVault`

| Function | Access |
|----------|--------|
| `lockTokens(wallet, assetId, providerId, amountUg, reason, requestId)` | TradeManager (`TRADE_MANAGER_ROLE` / setter) |
| `releaseEscrow(requestId, destination)` | TradeManager only |
| Views | Available / locked balances scoped by `(wallet, assetId, providerId)` |

Used on sell & redeem create; unlocked on reject/cancel; released on successful execute.

---

### 5.8 `TimelockController`

| Function | Access |
|----------|--------|
| `setWalletTimelock` / `setLotTimelock` | `AP_ROLE` |
| Mint-lot duration from governance | Applied during mint execute when `defaultTimelockDuration > 0` |
| TradeManager checks | Sell/redeem blocked if user wallet timelocked for asset |

---

## 6. Major business flows

### 6.1 User onboarding

```
registerUserFor → (off-chain KYC) → verifyKYCFor
```

- Grants `USER_ROLE` on TradeManager via registry callback.
- Until KYC verified: may buy under **non-KYC fiat cap** if eligible; may **not** sell/redeem.

### 6.2 Mint (fund AP retail pool)

```
proposeMintFor (AP, gasless)
  → approveRequestFor (per policy — commonly AT only if VP stripped)
  → executeRequest (admin)
  → AssetLedger.mintToPool + optional lot timelock
```

**Pre:** AP has `AP_ROLE` + `isOperator(providerId, ap)`; asset/provider active & supported; amount within caps.

**Post:** `providerPoolBalance(assetId, providerId)` increases. Buys consume this pool.

### 6.3 Buy (retail purchase)

```
createBuyRequestFor (user, gasless)
  → auto-executes in same transaction
  → inventory from provider pool → user holding
```

**Pre:** `USER_ROLE`; KYC or non-KYC rules; pool ≥ weight; provider binding; min µg / daily buy / non-KYC fiat caps.

**Post:** Holding up; pool down; certificate minted if needed. **No** separate `executeRequest`.

### 6.4 Sell (fiat exit)

```
createSellRequestFor (user, gasless)  → escrow lock, Proposed
  → approveRequestFor AP (must be operator of request.providerId)
  → approveRequestFor AT
  → executeRequest (admin)
  → releaseEscrow → sellPayout; decrease user supply
```

**Pre:** KYC eligible; holding ≥ amount; same active provider; not timelocked; sell caps.

**Off-chain:** fiat payout keyed by `payoutRefId`.

### 6.5 Redeem (physical delivery)

```
createRedeemRequestFor (user, gasless)  → escrow lock
  → approve: AP → [VP if required] → PAP → AT
  → executeRequest (admin)
  → releaseEscrow → redeemSink; decrease user supply
```

**Pre:** KYC; `amountUg >= minRedeemAmountUg`; binding / timelock / amount checks.

**Off-chain:** delivery keyed by `deliveryRefId`.

### 6.6 Burn (shrink AP pool)

```
proposeBurnFor (AP) → approvals (policy) → executeRequest → burnFromPool
```

### 6.7 Reject / cancel

| Action | Who | Effect |
|--------|-----|--------|
| `rejectRequestFor` | Policy roles (AP / VP / AT / PAP as coded) | Status Rejected; sell/redeem escrow unlocked |
| `cancelRequestFor` | Request initiator | Cancelled; escrow unlocked if locked |
| Buy | N/A | Already executed |

### 6.8 Provider lifecycle (admin)

```
registerProvider → setProviderAsset(s) → setAssetRouting → addProviderOperator
  → grantRole(AP_ROLE) on TradeManager + AssetLedger + TimelockController
```

Operator change: `removeProviderOperator` + `addProviderOperator` + role grants/revokes.

---

## 7. Accounting sketch (mental model)

| Event | Pool (`providerPoolBalance`) | User (`userHolding`) | Escrow |
|-------|------------------------------|----------------------|--------|
| Mint execute | ↑ | — | — |
| Buy | ↓ | ↑ | — |
| Sell create | — | available ↓ (locked) | ↑ lock |
| Sell execute | ↑ return inventory via decreaseSupply path* | ↓ permanent | released to sellPayout |
| Redeem create | — | locked | ↑ lock |
| Redeem execute | *as designed in decreaseSupply* | ↓ | released to redeemSink |
| Reject/cancel sell/redeem | — | unlocked | cleared |

\*Exact pool effect on sell execute is in `TradeManagerLib` / `AssetLedger.decreaseSupply` — verify inventory return semantics in audit.

---

## 8. Suggested audit focus areas

1. **Authority & upgrade** — UUPS, admin transfer, pause, forwarder change.
2. **Meta-tx spoofing** — `*For` actor vs signer / forwarder trust.
3. **Operator ↔ provider binding** — single-provider mapping; AP approval scoping.
4. **Provider routing** — incorrect sellPayout / redeemSink draining escrow.
5. **Escrow integrity** — double lock/release, reject/cancel completeness, requestId uniqueness.
6. **Inventory** — mint/buy/sell/redeem/burn conservation; binding conflicts.
7. **Policy mutability** — empty sell policy stuck state; VP strip behavior; AT-controlled policy risk.
8. **Non-KYC buy fiat accounting** — `_nonKycFiatPurchased` lifetime vs daily semantics.
9. **Co-sign path** — EIP-712 digest, nonce, role/operator checks parity with stepwise approve.
10. **Soulbound certificates** — transfer restrictions; per-(user, asset) uniqueness.
11. **Timelock** — sell/redeem gating; mint lot locking.
12. **Reentrancy / pausability** across TradeManager ↔ Ledger ↔ Escrow.

---

## 9. Testing & artifacts for estimation

| Artifact | Location |
|----------|----------|
| Source | `src/` |
| Libraries | `src/libraries/` |
| Interfaces | `src/interfaces/` |
| Foundry tests | `test/` |
| ABIs | `abi/*.abi.json` |
| Deploy / configure scripts | `script/` |
| Frontend handoff (ops, not audit-critical) | `docs/FRONTEND_INTEGRATION.md` |

Typical effort drivers: UUPS multi-proxy system, EIP-2771 gasless surface, multi-role ordered approvals, multi-asset/provider accounting, escrow, and co-sign alternate path.

---

## 10. Glossary

| Term | Meaning |
|------|---------|
| AP | Asset Provider (retail inventory / operator) |
| VP | Vault Provider (physical vault attestation — optional via flag) |
| AT | Authorized Trader / compliance approver |
| PAP | Physical Asset Provider (redeem) |
| Pool | Unsold inventory held for a `(assetId, providerId)` |
| Binding | User locked to one provider per asset while holding |
| µg | Microgram inventory unit |

---

*Document target: external auditors for scoping and estimation. Behavior is defined by Solidity source — treat this as a map, not a formal specification.*
