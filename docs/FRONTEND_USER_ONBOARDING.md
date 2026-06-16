# User Onboarding — Frontend Integration Guide

How to onboard investors on **Polygon Amoy** using Tresori gasless transactions.

**Scope of this doc:** register user → check status → admin verifies KYC.  
**Not in this doc:** buy and mint (see [FRONTEND_MINT_FLOW.md](./FRONTEND_MINT_FLOW.md) and [FRONTEND_INTEGRATION_GUIDE.md](./FRONTEND_INTEGRATION_GUIDE.md)).

---

## 1. What you are building

Two steps:

1. **User signs up** — frontend calls `registerUser` (gasless). User can **buy only** (with limits) while KYC is pending.
2. **Admin verifies KYC** — backend/admin calls `verifyKYC`. User gets **full access** (buy, sell, redeem).

The user's **wallet address** comes from Tresori MPC (`fromAddress`). You never pass the wallet into `registerUser` — the contract reads it from the transaction sender.

---

## 2. Config (put in frontend env)

| Key | Value |
|-----|-------|
| Chain ID | `80002` |
| RPC | Your Amoy RPC URL |
| `WHITELIST_REGISTRY` | `0xF6f299F574f136873e7Df9D54311AA62d09B9D52` |
| `TRADE_MANAGER` | `0x4AF90173D906021B9B56AA3dE31a0F26Ac44F9F3` |
| `GOVERNANCE_CONFIG` | `0x0a7B6033e405337fEF5F38254c02DE8354dEDbCa` |
| Tresori forwarder | `0x9DE37157464E5Ecf8FD0AB0d88D2B08c3cdfFf6D` |

**ABI:** `abi/WhitelistRegistry.abi.json`

---

## 3. Flow in plain English

```
User opens app → connects Tresori wallet
       ↓
Frontend calls registerUser(userId, kycRef)  [gasless]
       ↓
On-chain: profile created, KYC = Pending, USER_ROLE granted
       ↓
User can BUY only (limited by non-KYC fiat cap)
       ↓
Admin panel calls verifyKYC(wallet)  [admin wallet, not gasless]
       ↓
On-chain: KYC = Verified
       ↓
User can BUY / SELL / REDEEM (full access)
```

**Note:** Buy will still fail until the AP gold pool has inventory (mint flow). Onboarding only prepares the user account.

---

## 4. User states (what to show in UI)

After registration, use these **read calls** (no gas) to drive UI:

| Function | When `true` | Meaning |
|----------|-------------|---------|
| `hasUserRole(wallet)` | Registered | User completed `registerUser` |
| `isEligibleForNonKycUser(wallet)` | Pending KYC | Can use **buy only** (fiat cap applies) |
| `isEligible(wallet)` | KYC verified | **Full access** |

**`kycStatus`** from `getProfile(wallet)`:

| Value | Name | UI suggestion |
|-------|------|---------------|
| `0` | Pending | "KYC in progress" — show buy-only |
| `1` | Verified | "Verified" — full features |
| `2` | Rejected | "Not eligible" — block trades |

Default non-KYC buy cap (on-chain): `nonKycMaxBuyFiatAmount()` = `50000000` (INR minor units — align with product).

---

## 5. Step 1 — `registerUser` (frontend, gasless)

**Contract:** `WhitelistRegistry`  
**Function:** `registerUser(bytes32 userId, string kycRef)`

### Parameters

| Param | Type | What to pass |
|-------|------|--------------|
| `userId` | `bytes32` | Your **backend user id**, hashed. Not the wallet. Example: `ethers.id("user-12345")` or `ethers.id(dbUser.uuid)`. Store the same value in your DB. |
| `kycRef` | `string` | Your KYC case reference, e.g. `"KYC-SUMSUB-abc123"`. Free-form string for compliance audit. |

### Tresori call example

```ts
const userId = ethers.id(backendUser.id);   // bytes32 from your DB user id
const kycRef = backendUser.kycCaseRef;      // string from KYC provider

await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: WHITELIST_REGISTRY,
  functionName: "registerUser",
  params: [userId, kycRef],
  abi: ["function registerUser(bytes32 userId,string kycRef)"],
  fromAddress: userMpcWallet,   // Tresori MPC address — this becomes the on-chain wallet
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL,
});
```

### What happens on success (same tx)

- User profile saved on `WhitelistRegistry`
- `USER_ROLE` granted on `WhitelistRegistry` and `TradeManager`
- Event: `UserRegistered(wallet, userId)`

### Errors to handle

| Error | Meaning |
|-------|---------|
| `AlreadyRegistered` | This wallet already called `registerUser` — read profile instead of re-registering |

### After register — read calls for UI

```ts
const profile = await registry.getProfile(userMpcWallet);
const pendingBuyOk = await registry.isEligibleForNonKycUser(userMpcWallet);
const fullAccess = await registry.isEligible(userMpcWallet);
```

`getProfile` returns: `userId`, `wallet`, `kycStatus`, `walletStatus`, `userStatus`, `riskLevel`, `kycRef`, `registeredAt`.

---

## 6. Step 2 — `verifyKYC` (admin backend only)

**Contract:** `WhitelistRegistry`  
**Function:** `verifyKYC(address wallet)`  
**Who signs:** Admin wallet with `DEFAULT_ADMIN_ROLE` — **not** the user, **not** gasless in user app.

Call this from your **admin panel / backend** after off-chain KYC passes.

```ts
// Admin signer only — never in user-facing frontend
await registry.verifyKYC(userWalletAddress);
```

After success: `isEligible(wallet)` → `true`, `isEligibleForNonKycUser(wallet)` → `false`.

### Optional: admin registers user instead of self-service

If you skip user `registerUser` and onboard from admin panel:

`adminRegisterUser(bytes32 userId, address wallet, string kycRef)` — same admin signer, includes wallet explicitly.

---

## 7. Read-only helpers for buy UI (later)

When you add buy, validate against these **before** sending a tx:

```ts
await governance.minimumBuyGoldValueInUg();  // min gold per buy (µg)
await governance.maxAmountPerTx();             // max gold per tx (µg), default 1 kg
await governance.nonKycMaxBuyFiatAmount();     // pending-KYC fiat cap
await governance.dailyBuyCap();                // verified users only
```

Gold amounts are **micrograms (µg)**: `1 gram = 1_000_000`.

---

## 8. Ops verification (`cast` — for backend team)

Run after a user registers in the app to confirm they are set up correctly.

```shell
cd trade-smart-contract
source .env
export WALLET=0xUserMpcWalletAddress
```

**Profile + eligibility:**

```shell
cast call $WHITELIST_REGISTRY "getProfile(address)((bytes32,address,uint8,uint8,uint8,uint8,string,uint256))" $WALLET --rpc-url $AMOY_RPC_URL
cast call $WHITELIST_REGISTRY "isEligible(address)(bool)" $WALLET --rpc-url $AMOY_RPC_URL
cast call $WHITELIST_REGISTRY "isEligibleForNonKycUser(address)(bool)" $WALLET --rpc-url $AMOY_RPC_URL
cast call $WHITELIST_REGISTRY "hasUserRole(address)(bool)" $WALLET --rpc-url $AMOY_RPC_URL
```

**USER_ROLE on TradeManager (needed for buy later):**

```shell
USER_ROLE=$(cast keccak "USER_ROLE")
cast call $TRADE_MANAGER "hasRole(bytes32,address)(bool)" $USER_ROLE $WALLET --rpc-url $AMOY_RPC_URL
```

**Admin verify KYC from CLI (if admin UI not ready):**

```shell
cast send $WHITELIST_REGISTRY "verifyKYC(address)" $WALLET \
  --rpc-url $AMOY_RPC_URL --private-key $PRIVATE_KEY --legacy --gas-price 35gwei
```

### User ready for buy?

| Pending KYC (buy-only) | Verified KYC (full) |
|------------------------|---------------------|
| `hasUserRole` = true | `hasUserRole` = true |
| `isEligibleForNonKycUser` = true | `isEligible` = true |
| `kycStatus` = 0 | `kycStatus` = 1 |
| USER_ROLE on TradeManager = true | USER_ROLE on TradeManager = true |

**System ready for buy** (separate check — ops/mint team):

```shell
cast call $GOLD_NFT "totalAssetProviderBalance()(uint256)" --rpc-url $AMOY_RPC_URL
```

Must be `> 0` before any buy works. See [FRONTEND_MINT_FLOW.md](./FRONTEND_MINT_FLOW.md).

---

## 9. Integration checklist

**Frontend (user app)**

- [ ] Load `WHITELIST_REGISTRY` address and ABI
- [ ] On sign-up, call gasless `registerUser(userId, kycRef)` with Tresori `fromAddress`
- [ ] Encode `userId` as `bytes32` from backend user id
- [ ] After tx, read `getProfile` / `isEligibleForNonKycUser` for UI state
- [ ] Do **not** call `verifyKYC` from user app

**Admin backend**

- [ ] Call `verifyKYC(wallet)` when off-chain KYC passes
- [ ] Optionally use `adminRegisterUser` for manual onboarding

**Before enabling buy**

- [ ] User passes checklist in §8
- [ ] `totalAssetProviderBalance > 0` (mint completed)

---
