# STOEX Trade Smart Contract — Audit Remediation Report

**Audit:** Femto Security / Koshayojan Services DMCC — Document ID `2026-08-07-STOEX`  
**Remediation date:** 2026-08-10  
**Scope commit (pre-fix):** `e254001794e18014517f5b9c5b30861ae4205757`  
**Action:** Fresh Polygon Amoy redeploy (`version = 4` on core proxies)

---

## New Amoy addresses (use these going forward)

| Contract | Proxy |
|----------|--------|
| TradeManager | `0x5f1553F974F5Ae137Af52487EaCE01c8164cc9Cf` |
| AssetLedger | `0x464e01e2AbCA026DF92a612318D71cf20b43D4c2` |
| WhitelistRegistry | `0x1Dd88BD5Bf91c454894Be56D103EeDB75A7aF85C` |
| GovernanceConfig | `0x85636CBf6639366d3D72Aa7Bc9375F700685B05D` |
| AssetRegistry | `0x53E5FEa57B8854DE17214714e13b565b8a637031` |
| AssetProviderRegistry | `0x805Ae698602028A3f7fA3A9DF36FCB3595B6db7C` |
| EscrowVault | `0xCdD50B2D88d17DB7D4E161a08185931031aBe3C0` |
| TimelockController | `0x2A6EDE57E6F6864F2d406E8a0BB04964d4bc010a` |
| Tresori relayer (unchanged) | `0xB9CBD815098cc3d6A348bDfed995af91e2298d6D` |

**Admin:** `0xDb79cCBfFB614BCBf636a724D2E373cbAE36287d`  
**ABIs:** `abi/*.abi.json` / `abi.zip`  
**FE guide:** `docs/FRONTEND_INTEGRATION.md`

Previous Amoy proxies are obsolete. Users must re-onboard on the new `WhitelistRegistry`.

---

## Summary

| # | Severity | Disposition |
|---|----------|-------------|
| 01 | Critical | **Accepted** — not applicable as stated (Tresori trust model) |
| 02 | Critical | **Accepted** — same as 01 |
| 03 | High | **Fixed** |
| 04 | High | **Fixed** |
| 05 | High | **Fixed** (on-chain portion) |
| 06 | Medium | **Accepted** — not a vulnerability |
| 07 | Medium | **Fixed** |
| 08 | Medium | **Fixed** (lifetime + admin reset) |
| 09 | Medium | **Accepted** — residual admin-trust risk |
| 10 | Medium | **Fixed** |
| 11 | Medium | **Fixed** |
| 12 | Low | **Fixed** |
| 13 | Low | **Fixed** |
| 14 | Low | **Fixed** |

---

## Finding-by-finding

### 01 / 02 — Missing ERC2771 Context (Critical) — ACCEPTED

**Auditor claim:** Gasless `*For` functions take an explicit `user`/`wallet` and only check `msg.sender == trustedForwarder()`, so a compromised forwarder can impersonate anyone. Recommended adding `ERC2771Context` and removing explicit user params.

**Why we did not implement that remediation**

1. **Tresori does not append ERC-2771 suffix bytes.** Our gate (`StoexRelayerGate`) is documented for that model: only the trusted forwarder may call `*For`, and the app passes the MPC `fromAddress` explicitly.
2. **User authentication happens in Tresori (MPC session)** before the forwarder submits. Outsiders cannot call TradeManager/WhitelistRegistry `*For` directly — they hit `NotTrustedForwarder`.
3. **Standard ERC-2771 does not remove forwarder trust.** A malicious ERC-2771 forwarder can still append any address. Switching to ERC2771 would **break** the current Tresori SDK integration without improving the compromised-forwarder case.
4. **Tresori is an internal product** controlling the configured forwarder. Compromising it is treated as infrastructure compromise, not an open public exploit.

**Optional future harden (not in this release):** EIP-712 user/MPC signatures verified on-chain on each `*For` payload.

---

### 03 — `_nomineeTransferActive` soulbound bypass (High) — FIXED

**Issue:** During `nomineeTransferForAsset`, a global boolean allowed *any* transfer while true. An ERC-721 receiver on `toCustody` could reenter via `transferFrom` and move the token while the flag was set. `nonReentrant` on the outer function does not block that path through `_update`.

**Fix (`src/AssetLedger.sol`):** Nominee path now binds expected `(from, to, tokenId)`. `_update` allows a transfer only when the flag is set **and** those three match. A malicious callback that tries `transferFrom` to a third party no longer matches and reverts `Soulbound`.

---

### 04 — Missing role sync on wallet migration (High) — FIXED

**Issue:** `_migrateWallet` copied the profile but left `USER_ROLE` on the old wallet and did not grant roles on the new wallet / TradeManager.

**Fix (`src/WhitelistRegistry.sol`, `src/TradeManager.sol`, `ITradeManagerOnboarding`):**

- Revoke `USER_ROLE` on old wallet (registry + `revokeUserRoleFromRegistry`)
- Grant `USER_ROLE` on new wallet (registry + `grantUserRoleFromRegistry`)
- Update `_walletByUserId[userId] → newWallet`

---

### 05 — Non-KYC cap multi-wallet bypass (High) — FIXED (on-chain)

**Issue:** Cap was per-wallet; `userId` was not unique.

**Fix:**

- Unique `userId` on register (`UserIdAlreadyUsed` / `ZeroUserId`) — `WhitelistRegistry`
- Non-KYC fiat accumulator keyed by `userId` — `TradeManager` / `TradeManagerLib`

**Residual:** One human with many distinct off-chain `userId`s still needs KYC/ops controls. On-chain enforces one wallet per `userId` and one lifetime non-KYC pot per `userId`.

---

### 06 — Routing address “must be contracts” (Medium) — ACCEPTED

**Why not followed:** `sellPayout` / `redeemSink` are often EOAs by design. Requiring `extcodesize > 0` would break legitimate payout wallets. Non-zero checks already exist; misconfiguration is an admin ops risk, not an external exploit.

---

### 07 — `setTradeManager` one-shot (Medium) — FIXED

**Issue:** EscrowVault / TimelockController could not update `tradeManager` after first set.

**Fix:** Admin may update `tradeManager` anytime; emit `TradeManagerUpdated`. (`AlreadySet` removed.)

---

### 08 — No daily reset for non-KYC fiat (Medium) — FIXED (as lifetime)

**Product intent:** Cap is **lifetime** until KYC, not daily.

**Fix:** Keep lifetime accumulator (now by `userId`) and add `TradeManager.adminResetNonKycFiatPurchased(userId)` for support cases. Daily rollover was **not** implemented because it would change product policy incorrectly.

---

### 09 — Admin frontrun on `settlementRefId` (Medium) — ACCEPTED

**Why not followed:** Only `DEFAULT_ADMIN_ROLE` may `executeRequest`. With a single admin (or coordinated ops), commit-reveal / multi-sig adds complexity without material benefit. Residual risk is multi-admin race or stolen admin key — same class as any privileged executor. Not addressed in this release.

---

### 10 — Unbounded lot array DoS (Medium) — FIXED

**Issue:** `requireNotTimelocked` iterated all user lots → gas DoS after many buys.

**Fix (`TimelockController` + `TradeManagerLib`):** O(1) check via `userAssetLotLockMax[user][assetId]` / `isUserAssetLotTimelocked`.  
`setLotTimelock(user, assetId, lotId, untilTs)` updates the max.  
`overrideLotTimelock(user, assetId, lotId, requestId)` clears the lot and the max (admin may re-apply remaining locks).

---

### 11 / 12 — `setTradeManager` validation + events (Medium/Low) — FIXED

**Fix (`WhitelistRegistry`):** Require `tradeManager_.code.length > 0` (`NotContract`); emit `TradeManagerUpdated`.

---

### 13 — Missing `setTrustedForwarder` events (Low) — FIXED

**Fix:** `TrustedForwarderUpdated` on TradeManager, WhitelistRegistry, and AssetLedger.

---

### 14 — Asset precision unbounded (Low) — FIXED

**Fix (`GovernanceConfig.setAssetPrecision`):** Require `1 <= decimals_ <= 18` (`InvalidPrecision`).

---

## Files touched (implementation)

| Area | Files |
|------|--------|
| Roles / migration / userId | `WhitelistRegistry.sol`, `ITradeManagerOnboarding.sol`, `TradeManager.sol` |
| Non-KYC cap | `TradeManager.sol`, `TradeManagerLib.sol` |
| Nominee / soulbound | `AssetLedger.sol` |
| Timelock O(1) | `TimelockController.sol`, `ITimelockController.sol`, `TradeManagerLib.sol` |
| TradeManager link / events | `EscrowVault.sol`, `TimelockController.sol`, `WhitelistRegistry.sol` |
| Precision | `GovernanceConfig.sol` |
| Tests | `test/StoexPRD.t.sol` |

---

## Verification

- `forge test --match-contract StoexPRDTest` — pass (including new migration / userId / timelock / precision cases)
- On-chain smoke: `TradeManager.version() == 4`, admin = deployer, GOLD/AP1 wired, Tresori forwarder set

---

## FE / ops notes after redeploy

1. Point FE at new addresses + new `abi.zip`
2. Re-register users (`userId` unique per person)
3. KYC still required for sell/redeem
4. Lot timelock admin API is now `setLotTimelock(user, assetId, lotId, until)`
5. Optional later: `transferAdmin` to FE ops wallet `0xb445…` when upgrades are no longer needed from the deployer key
