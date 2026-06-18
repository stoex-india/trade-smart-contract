# User Onboarding — Frontend Integration Guide

How to onboard investors on **Polygon Amoy** using Tresori gasless transactions.

**Scope of this doc:** register user → check status → admin verifies KYC.  
**Not in this doc:** buy and mint (see [FRONTEND_MINT_FLOW.md](./FRONTEND_MINT_FLOW.md) and [FRONTEND_INTEGRATION_GUIDE.md](./FRONTEND_INTEGRATION_GUIDE.md)).

---

## 1. What you are building

Two steps:

1. **User signs up** — frontend calls `registerUserFor` (gasless via Tresori relayer). User can **buy only** (with limits) while KYC is pending.
2. **Admin verifies KYC** — backend/admin calls `verifyKYC`. User gets **full access** (buy, sell, redeem).

The user's **wallet address** (`fromAddress` in Tresori) must be passed as the **first argument** to `registerUserFor`. The Tresori relayer does not append ERC-2771 suffix bytes, so the contract cannot infer the wallet from `msg.sender`.

---

## 2. Config (put in frontend env)

| Key | Value |
|-----|-------|
| Chain ID | `80002` |
| RPC | Your Amoy RPC URL |
| `WHITELIST_REGISTRY` | *(see README deployment table)* |
| `TRADE_MANAGER` | *(see README deployment table)* |
| `GOVERNANCE_CONFIG` | *(see README deployment table)* |
| Tresori relayer | `RELAYER_SMART_CONTRACT` in `.env` — must match `trustedForwarder()` on registry |

**ABI:** `abi/WhitelistRegistry.abi.json`

---

## 3. Flow in plain English

```
User opens app → connects Tresori wallet
       ↓
Frontend calls registerUserFor(wallet, userId, kycRef)  [gasless via relayer]
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

**Relayer success:** Check the inner call succeeded in Tresori `RelayExecuted` (or equivalent) — the outer relayer tx can succeed while the inner `registerUserFor` reverts.

---

## 4. User states (what to show in UI)

After registration, use these **read calls** (no gas) to drive UI:

| Function | When `true` | Meaning |
|----------|-------------|---------|
| `hasUserRole(wallet)` | Registered | User completed `registerUserFor` |
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

## 5. Step 1 — `registerUserFor` (frontend, gasless)

**Contract:** `WhitelistRegistry`  
**Function:** `registerUserFor(address wallet, bytes32 userId, string kycRef)`

### Parameters

| Param | Type | What to pass |
|-------|------|--------------|
| `wallet` | `address` | Tresori MPC `fromAddress` — the investor wallet |
| `userId` | `bytes32` | Your **backend user id**, hashed. Example: `ethers.id("user-12345")`. Store the same value in your DB. |
| `kycRef` | `string` | Your KYC case reference, e.g. `"KYC-SUMSUB-abc123"`. |

### Tresori call example

```ts
const userId = ethers.id(backendUser.id);
const kycRef = backendUser.kycCaseRef;

await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: WHITELIST_REGISTRY,
  functionName: "registerUserFor",
  params: [userMpcWallet, userId, kycRef],
  abi: ["function registerUserFor(address wallet,bytes32 userId,string kycRef)"],
  fromAddress: userMpcWallet,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL,
});
```

### What happens on success (inner call)

- User profile saved on `WhitelistRegistry`
- `USER_ROLE` granted on `WhitelistRegistry` and `TradeManager`
- Event: `UserRegistered(wallet, userId)`

### Errors to handle

| Error | Meaning |
|-------|---------|
| `AlreadyRegistered` | Wallet already registered — read profile instead |
| `NotTrustedForwarder` | Call did not originate from configured relayer |

### After register — read calls for UI

```ts
const profile = await registry.getProfile(userMpcWallet);
const pendingBuyOk = await registry.isEligibleForNonKycUser(userMpcWallet);
const fullAccess = await registry.isEligible(userMpcWallet);
```

---

## 6. Step 2 — `verifyKYC` (admin backend only)

**Contract:** `WhitelistRegistry`  
**Function:** `verifyKYC(address wallet)`  
**Who signs:** Admin wallet with `DEFAULT_ADMIN_ROLE` — **not** the user, **not** gasless in user app.

### Optional: admin registers user instead of self-service

`adminRegisterUser(bytes32 userId, address wallet, string kycRef)` — same admin signer, includes wallet explicitly.

---

## 7. Read-only helpers for buy UI (later)

When you add buy, use gasless `createBuyRequestFor(user, ...)` on `TradeManager` (see [FRONTEND_INTEGRATION_GUIDE.md](./FRONTEND_INTEGRATION_GUIDE.md)).

```ts
await governance.minimumBuyGoldValueInUg();
await governance.maxAmountPerTx();
await governance.nonKycMaxBuyFiatAmount();
await governance.dailyBuyCap();
```

Gold amounts are **micrograms (µg)**: `1 gram = 1_000_000`.

---

## 8. Ops verification (`cast`)

```shell
cd trade-smart-contract
source .env
export WALLET=0xUserMpcWalletAddress
```

```shell
cast call $WHITELIST_REGISTRY "getProfile(address)((bytes32,address,uint8,uint8,uint8,uint8,string,uint256))" $WALLET --rpc-url $AMOY_RPC_URL
cast call $WHITELIST_REGISTRY "isEligible(address)(bool)" $WALLET --rpc-url $AMOY_RPC_URL
cast call $WHITELIST_REGISTRY "isEligibleForNonKycUser(address)(bool)" $WALLET --rpc-url $AMOY_RPC_URL
```

---

## 9. Integration checklist

**Frontend (user app)**

- [ ] Load `WHITELIST_REGISTRY` address and ABI
- [ ] On sign-up, call gasless `registerUserFor(wallet, userId, kycRef)` with explicit `wallet` = Tresori `fromAddress`
- [ ] Verify inner relay success, not only outer tx hash
- [ ] Do **not** call `verifyKYC` from user app

**Admin backend**

- [ ] Call `verifyKYC(wallet)` when off-chain KYC passes
- [ ] Optionally use `adminRegisterUser` for manual onboarding

**Before enabling buy**

- [ ] User passes eligibility checks in §8
- [ ] `totalAssetProviderBalance > 0` (mint completed)

---

## Deprecated

`registerUser(bytes32 userId, string kycRef)` was removed. It relied on ERC-2771 `_msgSender()`, which does not work with the Tresori relayer. Use **`registerUserFor`** only.
