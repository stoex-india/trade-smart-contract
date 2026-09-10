# STOEX smart contracts — go-live checklist

Use this before any **Polygon mainnet** (chain `137`) production cutover.  
Companion docs: [MAINNET-DEPLOYMENT-SOP.md](MAINNET-DEPLOYMENT-SOP.md) · [CONTRACT-INVENTORY.md](CONTRACT-INVENTORY.md)

**Release under review:** V1 simplified trade model (`version = 4`) — buy / sell / redeem only. No on-chain mint/burn. Admin + user roles only on the trade path.

Mark each item `[x]` only after evidence exists (tx hash, screenshot, or signed note). Do not go live with unchecked **Blocker** items.

---

## Sign-off

| Role | Name | Date | Signature / note |
|------|------|------|------------------|
| Smart-contract owner | | | |
| Security / audit owner | | | |
| Ops / admin key custodian | | | |
| Frontend / product | | | |
| Backend / payments | | | |
| Go / no-go (final) | | | |

---

## 1. Code freeze and audit (Blocker)

- [ ] Git tag / commit hash of the release is recorded (no uncommitted `src/` changes).
- [ ] `forge build` succeeds with current `foundry.toml` (`via_ir = true`, `optimizer_runs = 1`).
- [ ] `forge test -vv` is green (including `StoexPRD.t.sol`).
- [ ] Femto audit remediation is accepted as the live baseline (`docs/AUDIT_REMEDIATION_REPORT.md`). Residual accepted findings (01/02 forwarder trust, 06 routing EOAs, 09 admin settlement race) are signed off by product + security.
- [ ] ABIs in `abi/*.abi.json` match the freeze commit (regenerate if contracts changed).
- [ ] `TradeManager` runtime bytecode is under the **24,576 B** EIP-170 limit (confirm with `forge build` / `cast codesize` on the implementation after deploy).

---

## 2. Testnet rehearsal (Blocker)

Complete a full dress rehearsal on **Polygon Amoy** (`80002`) with the **same scripts and config shape** that will be used on mainnet.

- [ ] Fresh (or current) Amoy proxies exist and are listed in [CONTRACT-INVENTORY.md](CONTRACT-INVENTORY.md).
- [ ] Source verified on [Amoy Polygonscan](https://amoy.polygonscan.com).
- [ ] GOLD + SILVER registered; provider `AP1` (MMTC) active with sell payout + redeem sink set.
- [ ] Trusted forwarder on `TradeManager`, `WhitelistRegistry`, and `AssetLedger` equals the Tresori **mainnet-intended** relayer (or the Amoy relayer if Tresori uses a different address per chain — record both).
- [ ] Gasless **register → (optional KYC) → buy** works end-to-end from the production frontend build pointed at Amoy.
- [ ] **Sell** and **redeem**: create (gasless) → admin `executeRequest(requestId, settlementRef)` (paid).
- [ ] Pause / unpause exercised on `TradeManager` and `AssetLedger` in a non-prod window; confirm buys revert while paused.
- [ ] Admin rotation path is understood: `setInitialAdmin` (once) then `transferAdmin` on **every** proxy if ops admin ≠ deployer.

---

## 3. Keys, wallets, and custody (Blocker)

Treat mainnet `PRIVATE_KEY` / MPC shares as production secrets. Never commit `.env`.

| Wallet | Purpose | Custody | Funded with POL? |
|--------|---------|---------|------------------|
| Deployer | `initialize` + one-shot `setInitialAdmin` | | [ ] |
| `INITIAL_ADMIN` | `DEFAULT_ADMIN_ROLE` — execute/reject, pause, UUPS, governance, registries | | [ ] |
| Tresori relayer | Trusted forwarder for `*For` gasless calls | Tresori infra | n/a |
| Sell payout (`ASSET_PROVIDER_PAYOUT`) | Off-chain settlement routing for sell | | n/a |
| Redeem sink (`REDEEM_SINK`) | Off-chain routing for redeem | | n/a |
| Provider operator (optional) | Metadata only in V1 (not a trade approver) | | n/a |

- [ ] Deployer and admin are **separate** wallets for production **or** a written exception is signed (Amoy currently uses the same address for both).
- [ ] Admin key is in MPC / hardware / multi-person control. A stolen admin key can execute sells, reject requests, pause, and upgrade proxies.
- [ ] Backup / recovery procedure for admin exists (who calls `transferAdmin` if the current admin is lost — only the current admin can rotate).
- [ ] Deployer key will be **decommissioned from day-to-day use** after `setInitialAdmin` (it cannot call admin functions; it also cannot rotate admin).
- [ ] POL balance on deployer covers ~8 implementations + 8 proxies + admin wiring (budget **≥ 2 POL**; top up if gas spikes).
- [ ] POL balance on admin covers post-deploy wiring, verification retries, first execute/reject, and emergency pause.

---

## 4. On-chain policy values (Blocker)

Confirm these **before** broadcast. `GovernanceConfig.initialize` seeds the defaults below. Change on-chain after deploy if product disagrees.

| Parameter | Default at initialize | Production decision |
|-----------|----------------------|---------------------|
| `requestExpiryDuration` | 7 days | |
| `minRedeemAmountUg` | `10_000_000` (10 g) | |
| `maxAmountPerTx` | `1_000_000_000` (1 kg) | |
| `nonKycMaxBuyFiatAmount` | `50_000_000` | |
| `defaultTimelockDuration` | `0` | |
| `defaultPrecision` | `6` | |
| GOLD / SILVER `dailyBuyCap` | 10 kg | |
| GOLD / SILVER `dailySellCap` | 5 kg | |
| GOLD / SILVER `minimumBuyValueInUg` | `1_000` (0.001 g) | |

Also confirm:

- [ ] `DEFAULT_PROVIDER_LABEL` / `DEFAULT_PROVIDER_NAME` (Amoy: `AP1` / `MMTC`).
- [ ] `ASSET_PROVIDER_PAYOUT` and `REDEEM_SINK` are the **production** routing addresses (EOAs allowed).
- [ ] `RELAYER_SMART_CONTRACT` is the **Polygon mainnet** Tresori relayer (do not reuse Amoy if Tresori issues a new address).
- [ ] Amounts remain **micrograms** (`1 g = 1_000_000` µg) in every FE/BE integration.

---

## 5. External dependencies (Blocker)

- [ ] Polygon **mainnet** HTTPS RPC is dedicated (Alchemy / Infura / QuickNode), not a public rate-limited endpoint.
- [ ] `POLYGONSCAN_API_KEY` can verify chain `137` (same key as Amoy in this repo’s Foundry config).
- [ ] Tresori gasless (relayer + facilitator) is live on Polygon mainnet; `fromAddress` = MPC wallet.
- [ ] Backend settlement-ref hashing (`SHA-256(secret ‖ plaintext)`) is deployed; secret is **not** on-chain.
- [ ] Payments / KYC systems will write unique `userId` values (reuse across wallets reverts `UserIdAlreadyUsed`).

---

## 6. Deployment execution (Blocker)

Follow [MAINNET-DEPLOYMENT-SOP.md](MAINNET-DEPLOYMENT-SOP.md) in order. Do not skip dry-run.

- [ ] Dry-run (`forge script` without `--broadcast`) against mainnet RPC succeeds.
- [ ] Broadcast completed; all **eight proxies** exist on-chain (confirm on Polygonscan, not only console output).
- [ ] `setInitialAdmin` succeeded on every proxy (`adminInitialized == true`).
- [ ] If `INITIAL_ADMIN ≠ deployer`: `ConfigureDeployment.s.sol` (or `WireProxiesAdmin.s.sol` + asset/provider registration) completed with the **admin** key.
- [ ] GOLD + SILVER + default provider + routing + `TRADE_MANAGER_ROLE` on `AssetLedger` + `setTradeManager` on escrow / timelock / whitelist.
- [ ] Trusted forwarder matches Tresori on TM / WR / AL.
- [ ] All proxies + implementations verified on Polygonscan.
- [ ] Inventory sheet updated with mainnet addresses and explorer links.

---

## 7. Post-deploy smoke (Blocker)

Run on **mainnet** with a dedicated test user (tiny amounts). Record request IDs.

- [ ] `version()` on core proxies is `4`.
- [ ] `hasRole(DEFAULT_ADMIN_ROLE, INITIAL_ADMIN)` is true on every proxy.
- [ ] `AssetLedger.hasRole(TRADE_MANAGER_ROLE, TradeManager)` is true.
- [ ] `trustedForwarder()` equals `RELAYER_SMART_CONTRACT` on TM / WR / AL.
- [ ] Provider `AP1` active; GOLD + SILVER supported; payout / sink non-zero.
- [ ] Register user (gasless) → `USER_ROLE` on whitelist + TradeManager.
- [ ] Pending-KYC buy under `nonKycMaxBuyFiatAmount` **or** verified-KYC buy — holding increases; certificate minted.
- [ ] Sell: escrow lock → admin execute → circulating / lifetimeSoldBack update.
- [ ] Redeem (≥ min amount): escrow → admin execute → lifetimeRedeemed update.
- [ ] Frontend, backend, and this inventory all point at the **same** eight proxy addresses.

---

## 8. Incident readiness (Blocker)

- [ ] On-call knows how to **pause** `TradeManager` and `AssetLedger` (admin key / MPC).
- [ ] Pause does **not** by itself settle in-flight sell/redeem; ops knows to `rejectRequest` / wait TTL `expireRequest` as needed.
- [ ] UUPS upgrades are **not** in the go-live plan. Any later upgrade needs a separate change ticket + storage-layout review.
- [ ] Runbook links: this checklist, SOP, inventory, [FRONTEND_INTEGRATION.md](FRONTEND_INTEGRATION.md).

---

## 9. Cutover and communications

- [ ] Frontend env switched from Amoy (`80002`) to Polygon (`137`) with new addresses + ABIs.
- [ ] Users are **not** migrated from Amoy; they must re-register on mainnet `WhitelistRegistry`.
- [ ] Support / status page notes the go-live time and that Amoy balances are test-only.
- [ ] Inventory “Mainnet status” set to **Live**.

---

## Go / no-go

| Decision | Date | Notes |
|----------|------|-------|
| **GO** / **NO-GO** | | |

**NO-GO if:** unverified bytecode, wrong forwarder, admin not set, GOLD/AP1 unwired, pause untested, or Tresori mainnet relayer unknown.
