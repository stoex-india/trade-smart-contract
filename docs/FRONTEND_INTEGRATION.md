# Frontend integration guide (simple)

Polygon **Amoy** (`chainId: 80002`). All `*For` functions are **gasless** via Tresori relayer. Admin `grantRole` / `executeRequest` use a **normal wallet transaction** (not gasless).

Use ABIs from `abi/*.abi.json`.

---

## 1. Contract addresses (Amoy)

| Contract | Address |
|----------|---------|
| TradeManager | `0x1bD7e862C403244650B9028C2eDBcC7a0480f547` |
| AssetLedger | `0x411Ae02A0DA08D51EeD84fFBD58cE385E0fF9fb3` |
| AssetRegistry | `0x57a01603dDb311d8b394dcE78062394b578622Eb` |
| AssetProviderRegistry | `0x3FC8b7DA2fa7801a81F6e59a8929e54636D51e93` |
| WhitelistRegistry | `0xE5603C1e95F433E01A4737bf8d800f10D19648A8` |
| GovernanceConfig | `0x9d8712D90Af381829fb97eC16D44C063DF30f19e` |
| TimelockController | `0x109c4ce0db4a98e107D631f2ADF70166587985f4` |
| EscrowVault | `0xB33D00a16de5F9eB77753b0251E6af92b8c5AF5B` |
| Tresori relayer | `0xB9CBD815098cc3d6A348bDfed995af91e2298d6D` |

---

## 2. Asset & provider IDs

IDs are `bytes32` = `keccak256("LABEL")`. Frontend computes the same way:

```ts
import { keccak256, toUtf8Bytes, id } from "ethers";

const GOLD   = keccak256(toUtf8Bytes("GOLD"));
const SILVER = keccak256(toUtf8Bytes("SILVER"));
const AP1    = keccak256(toUtf8Bytes("AP1"));
const AP2    = keccak256(toUtf8Bytes("AP2"));
```

### Assets

| Label | `assetId` (`bytes32`) | Symbol | Name |
|-------|------------------------|--------|------|
| `GOLD` | `0xdbd17891fc491ac6717dd01ab1f90f82509f1f2e91cd5066f68805860fbdeb72` | AU | Gold |
| `SILVER` | `0x75e02a3ee626f5d4b8bc98cc8de5b102ee067608b6066832ffdc71f78445ac2b` | AG | Silver |

### Providers

| Label (slug) | `providerId` (`bytes32`) | Display name (on-chain) |
|--------------|--------------------------|-------------------------|
| `AP1` | `0x18b117340645cfb38a7414f6a51f090965f4e22ead292d9dad633e05e91ff811` | **MMTC** |
| `AP2` | `0x8e02c38093eb2f04539e87bd66824c36f9a6e087fe915d21716d4c6d77434c62` | **amrapali** |

**Important:** Pass `keccak256("AP1")` or `keccak256("AP2")` as `providerId` in all `TradeManager` calls. Display names (**MMTC**, **amrapali**) come from `getProvider(providerId)` only — do not hash the display name unless that slug is registered separately.

**Operator wallets:** read from chain — `getOperators(providerId)` or `isOperator(providerId, wallet)` on `AssetProviderRegistry`. **Currently empty on Amoy** until admin registers (section 5). Admin registers via section 5.

**Registered on Amoy:** assets `GOLD`, `SILVER` · providers **`AP1`** (MMTC) and **`AP2`** (amrapali), both supporting GOLD and SILVER.

**Amounts:** always **micrograms (µg)**. `1 gram = 1_000_000` µg.

---

## 3. Gasless vs normal tx

| Who | Function | Contract | Gasless? |
|-----|----------|----------|----------|
| User | `registerUserFor` | WhitelistRegistry | Yes |
| User | `verifyKYCFor` | WhitelistRegistry | Yes |
| User | `createBuyRequestFor` | TradeManager | Yes |
| User | `createSellRequestFor` | TradeManager | Yes |
| AP | `proposeMintFor` | TradeManager | Yes |
| AP / VP / AT / PAP | `approveRequestFor` | TradeManager | Yes |
| Admin | `grantRole`, `addProviderOperator`, `registerProvider`, etc. | AssetProviderRegistry, TradeManager, AssetLedger, … | **No** — use `writeMpcSmartContractTransaction` |
| Admin | `executeRequest` | TradeManager | **No** — use `writeMpcSmartContractTransaction` |

**Gasless** (`writeGaslessMpcSmartContractTransaction`): only contracts with a trusted forwarder and `*For` entrypoints — `TradeManager`, `WhitelistRegistry`, `AssetLedger`. The relayer is `0xB9CBD815098cc3d6A348bDfed995af91e2298d6D`.

**Admin / paid** (`writeMpcSmartContractTransaction`): admin MPC wallet signs and broadcasts directly on `rpcUrl`. **`AssetProviderRegistry` has no forwarder** — gasless calls to it will not change state (relayer tx may succeed but inner call fails).

**Gasless pattern (Tresori):** always pass the **wallet** as the first argument in `*For` functions. Use `fromAddress` = that same wallet in the SDK.

---

## 4. User onboarding

### Step A — Register (gasless)

**Contract:** `WhitelistRegistry`  
**Function:** `registerUserFor(address wallet, bytes32 userId, string kycRef)`

```ts
const userId = id(backendUser.id); // e.g. id("user-12345")
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: WHITELIST_REGISTRY,
  functionName: "registerUserFor",
  params: [userWallet, userId, "KYC-REF-123"],
  abi: ["function registerUserFor(address wallet,bytes32 userId,string kycRef)"],
  fromAddress: userWallet,
  chain, clientShare, sessionId, rpcUrl,
});
```

**After register — read (no gas):**

```ts
await whitelist.hasUserRole(userWallet);           // true if registered
await whitelist.isEligibleForNonKycUser(userWallet); // true → buy only (fiat cap)
await whitelist.isEligible(userWallet);            // false until KYC verified
await whitelist.getProfile(userWallet);          // kycStatus: 0=Pending, 1=Verified
```

### Step B — Off-chain KYC

User completes KYC in your app (Sumsub, etc.).

### Step C — Verify KYC on-chain (gasless)

**Contract:** `WhitelistRegistry`  
**Function:** `verifyKYCFor(address user)` — **only** via relayer, **user** calls (not admin).

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: WHITELIST_REGISTRY,
  functionName: "verifyKYCFor",
  params: [userWallet],
  abi: ["function verifyKYCFor(address user)"],
  fromAddress: userWallet,
  chain, clientShare, sessionId, rpcUrl,
});
```

**After verify:**

```ts
await whitelist.isEligible(userWallet); // true → buy, sell, redeem allowed
```

---

## 5. Admin — roles & provider setup (paid MPC tx)

Admin MPC wallet uses **`writeMpcSmartContractTransaction`** (not gasless). Used from your **admin panel / backend**, not the user app.

**Role constants:** `keccak256("AP_ROLE")`, `keccak256("VP_ROLE")`, `keccak256("AT_ROLE")`, `keccak256("PAP_ROLE")`.

| Role | `grantRole` on these contracts |
|------|--------------------------------|
| **AP** | `TradeManager`, `AssetLedger`, `TimelockController` **and** `addProviderOperator` on `AssetProviderRegistry` (see below) |
| **VP** | `TradeManager` |
| **AT** | `TradeManager`, `GovernanceConfig`, `WhitelistRegistry`, `TimelockController` |
| **PAP** | `TradeManager` |

### AP wallet — full setup (required)

AP mint/approve will **not** work unless **both** are done:

1. **`AP_ROLE`** on the three contracts above  
2. **`addProviderOperator(providerId, apWallet)`** on `AssetProviderRegistry`

**Contract:** `AssetProviderRegistry`  
**Functions:** `addProviderOperator(bytes32 providerId, address wallet)` · `removeProviderOperator(bytes32 providerId, address wallet)`

```ts
const AP_ROLE = keccak256(toUtf8Bytes("AP_ROLE"));
const AP1 = keccak256(toUtf8Bytes("AP1"));
const adminWallet = "0xb4451002742d6589781C5AfA6A213c8F6c1db087";
const apWallet = "0x2FF6463BC8d5264163063b68897B6B603C5aF9c4";

const TRADE_MANAGER = "0x1bD7e862C403244650B9028C2eDBcC7a0480f547";
const ASSET_LEDGER = "0x411Ae02A0DA08D51EeD84fFBD58cE385E0fF9fb3";
const TIMELOCK_CONTROLLER = "0x109c4ce0db4a98e107D631f2ADF70166587985f4";
const ASSET_PROVIDER_REGISTRY = "0x3FC8b7DA2fa7801a81F6e59a8929e54636D51e93";

// 1 — register operator on AssetProviderRegistry (PAID, not gasless)
await TreSori().writeMpcSmartContractTransaction({
  contractAddress: ASSET_PROVIDER_REGISTRY,
  functionName: "addProviderOperator",
  params: [AP1, apWallet],
  abi: ["function addProviderOperator(bytes32 providerId, address wallet)"],
  fromAddress: adminWallet,
  chain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL,
});

// 2 — AP_ROLE on three contracts (same SDK method, repeat per contract)
for (const addr of [TRADE_MANAGER, ASSET_LEDGER, TIMELOCK_CONTROLLER]) {
  await TreSori().writeMpcSmartContractTransaction({
    contractAddress: addr,
    functionName: "grantRole",
    params: [AP_ROLE, apWallet],
    abi: ["function grantRole(bytes32 role, address account)"],
    fromAddress: adminWallet,
    chain,
    clientShare,
    sessionId,
    rpcUrl: AMOY_RPC_URL,
  });
}
```

**Verify (read — any RPC, no gas):**

```ts
await assetProviderRegistry.isOperator(AP1, apWallet); // must be true
await tradeManager.hasRole(AP_ROLE, apWallet);         // must be true
await assetProviderRegistry.getOperators(AP1);         // includes apWallet
```

### Change AP operator wallet

admin **removes old, adds new**, then updates roles:

```ts
await assetProviderRegistry.removeProviderOperator(providerId, oldApWallet);
await assetProviderRegistry.addProviderOperator(providerId, newApWallet);

await tradeManager.grantRole(AP_ROLE, newApWallet);
await assetLedger.grantRole(AP_ROLE, newApWallet);
await timelock.grantRole(AP_ROLE, newApWallet);
// optional: revokeRole(AP_ROLE, oldApWallet) on each contract
```

### Add a new provider (admin)

On `AssetProviderRegistry` (in order):

| Step | Function |
|------|----------|
| 1 | `registerProvider(keccak256("SLUG"), "Display Name")` |
| 2 | `setProviderAsset(providerId, assetId, true)` per asset |
| 3 | `setAssetRouting(providerId, assetId, sellPayout, redeemSink)` per asset — real AP payout/redeem addresses |
| 4 | `addProviderOperator(providerId, apWallet)` |
| 5 | `grantRole(AP_ROLE, apWallet)` on TradeManager, AssetLedger, TimelockController |

Call `setAssetRouting` again anytime to **update** sell/redeem addresses for an existing provider.

---

## 6. Mint flow (fund AP pool before buys)

User buys debit `AssetLedger.providerPoolBalance(assetId, providerId)`. Mint first.

**Approvals:** AT only (`vpRequiredForApprovals` is `false` on Amoy — no VP step for Mint/Burn/Redeem)  
**Execute:** admin `executeRequest(requestId)`

### Step 1 — AP proposes mint (gasless)

**Contract:** `TradeManager`  
**Function:** `proposeMintFor(address ap, bytes32 assetId, bytes32 providerId, uint256 amountUg, bytes32 vaultReceiptId, MintLotMeta lot)`

**Example — mint 100g GOLD to AP1 pool:**

```ts
const amountUg = 100_000_000n; // 100 grams
const vaultReceiptId = id("vault-receipt-001");
const lot = {
  assetId: GOLD,
  providerId: AP1,
  vaultReceiptId,
  batchId: id("batch-1"),
  purity: 999, // 99.9% in basis points style per your product
  depositTimestamp: Math.floor(Date.now() / 1000),
  vpId: vpWallet,
  lockUntilTs: 0,
  amountUg,
};

const { /* requestId from events or return */ } = await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "proposeMintFor",
  params: [apWallet, GOLD, AP1, amountUg, vaultReceiptId, lot],
  abi: [/* use abi/TradeManager.abi.json */],
  fromAddress: apWallet,
  chain, clientShare, sessionId, rpcUrl,
});
```

**Silver example:** same call with `SILVER` instead of `GOLD`.

### Step 2 — AT approves (gasless)

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "approveRequestFor",
  params: [atWallet, requestId],
  abi: ["function approveRequestFor(address approver,uint256 requestId)"],
  fromAddress: atWallet,
  chain, clientShare, sessionId, rpcUrl,
});
```

### Step 3 — Admin executes (normal tx)

```ts
await tradeManager.executeRequest(requestId); // admin signer, paid gas
```

### Step 4 — Verify pool (read)

```ts
await assetLedger.providerPoolBalance(GOLD, AP1); // should be >= buy size
```

---

## 7. User buy

**Auto-executes** — no `executeRequest` needed.

**Contract:** `TradeManager`  
**Function:** `createBuyRequestFor(address user, bytes32 assetId, bytes32 providerId, uint256 weightUg, uint256 fiat_value, bytes32 payment_ref, bytes32 txDetailsHash)`

**Pre-checks (read):**

```ts
await whitelist.isEligible(user) || await whitelist.isEligibleForNonKycUser(user);
await assetRegistry.isActive(GOLD);
await assetProviderRegistry.providerSupportsAsset(AP1, GOLD);
await assetLedger.providerPoolBalance(GOLD, AP1) >= weightUg;
```

**Example — buy 1g GOLD from AP1:**

```ts
const weightUg = 1_000_000n;
const fiatValue = 850000n; // INR minor units — your product rules
const paymentRef = id("payment-abc");
const txDetailsHash = id("upi-txn-hash");

await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createBuyRequestFor",
  params: [userWallet, GOLD, AP1, weightUg, fiatValue, paymentRef, txDetailsHash],
  abi: ["function createBuyRequestFor(address,bytes32,bytes32,uint256,uint256,bytes32,bytes32)"],
  fromAddress: userWallet,
  chain, clientShare, sessionId, rpcUrl,
});
```

**Check balance after buy:**

```ts
await assetLedger.userHolding(userWallet, GOLD, AP1); // µg
await assetLedger.userActiveProvider(userWallet, GOLD); // should be AP1
```

User must use the **same** `providerId` for future sells of that asset until balance is zero.

---

## 8. User sell

**Approvals:** AP → AT · then admin **executeRequest**

### Step 1 — User creates sell (gasless)

**Function:** `createSellRequestFor(address user, bytes32 assetId, bytes32 providerId, uint256 amountUg, bytes32 payoutRefId)`

Requires `isEligible(user)` === true (KYC verified).

```ts
const amountUg = 500_000n; // 0.5g
const payoutRef = id("sell-payout-001");

await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createSellRequestFor",
  params: [userWallet, GOLD, AP1, amountUg, payoutRef],
  abi: ["function createSellRequestFor(address,bytes32,bytes32,uint256,bytes32)"],
  fromAddress: userWallet,
  chain, clientShare, sessionId, rpcUrl,
});
```

### Step 2 — AP approves (gasless)

```ts
// approveRequestFor(apWallet, requestId)
```

### Step 3 — AT approves (gasless)

```ts
// approveRequestFor(atWallet, requestId)
```

### Step 4 — Admin executes (normal tx)

```ts
await tradeManager.executeRequest(requestId);
```

### Step 5 — Verify (read)

```ts
await assetLedger.userHolding(userWallet, GOLD, AP1); // decreased
await tradeManager.getRequestStatus(requestId); // Executed
```

---

## 9. Useful read calls (no gas)

| What | Contract | Function |
|------|----------|----------|
| User KYC / eligibility | WhitelistRegistry | `getProfile`, `isEligible`, `isEligibleForNonKycUser` |
| User balance | AssetLedger | `userHolding(user, assetId, providerId)` |
| User’s provider for asset | AssetLedger | `userActiveProvider(user, assetId)` |
| AP pool depth | AssetLedger | `providerPoolBalance(assetId, providerId)` |
| Asset active? | AssetRegistry | `isActive(assetId)` |
| Provider name | AssetProviderRegistry | `getProvider(providerId)` |
| Request status | TradeManager | `getRequestStatus(requestId)` |
| Min buy / caps | GovernanceConfig | `minimumBuyValueInUg(assetId)`, `maxAmountPerTx()` |

---

## 10. End-to-end order

```
1. Admin: grant AP / VP / AT roles + `addProviderOperator` for AP
2. Admin: mint GOLD/SILVER to AP1 pool (mint flow)
3. User: registerUserFor
4. User: verifyKYCFor (after off-chain KYC)
5. User: createBuyRequestFor (GOLD + AP1)
6. User: createSellRequestFor → AP + AT approve → admin executeRequest
```

---

## 11. Reject / cancel a pending request

Does **not** apply to **Buy** (buys auto-execute).

| Action | Who | Function | Gasless? |
|--------|-----|----------|----------|
| **Reject** | AP, VP, AT, or PAP | `rejectRequestFor(rejector, requestId, reason)` | Yes |
| **Cancel** | Request initiator (user/AP) | `cancelRequestFor(initiator, requestId)` | Yes |
| **Block execute** | Admin | Do not call `executeRequest` | — |

**Reject example (gasless):**

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "rejectRequestFor",
  params: [atWallet, requestId, "Compliance hold"],
  abi: ["function rejectRequestFor(address rejector,uint256 requestId,string reason)"],
  fromAddress: atWallet,
  chain, clientShare, sessionId, rpcUrl,
});
```

- **Sell / Redeem:** escrow unlocks; user gets metal back.
- **Mint / Burn:** pool unchanged; status → `Rejected`.
- Verify: `getRequestStatus(requestId)` → Rejected.

