# Frontend integration guide

Polygon **Amoy** (`chainId: 80002`).

- Gasless user calls: Tresori `writeGaslessMpcSmartContractTransaction` (`*For` functions)
- Admin execute / reject: Tresori `writeMpcSmartContractTransaction` (paid)
- ABIs: `abi/*.abi.json`
- Amounts: **micrograms (µg)** — `1 gram = 1_000_000` µg

---

## 1. Contract addresses (Amoy)

| Contract | Address |
|----------|---------|
| TradeManager | `0x5f1553F974F5Ae137Af52487EaCE01c8164cc9Cf` |
| AssetLedger | `0x464e01e2AbCA026DF92a612318D71cf20b43D4c2` |
| AssetRegistry | `0x53E5FEa57B8854DE17214714e13b565b8a637031` |
| AssetProviderRegistry | `0x805Ae698602028A3f7fA3A9DF36FCB3595B6db7C` |
| WhitelistRegistry | `0x1Dd88BD5Bf91c454894Be56D103EeDB75A7aF85C` |
| GovernanceConfig | `0x85636CBf6639366d3D72Aa7Bc9375F700685B05D` |
| TimelockController | `0x2A6EDE57E6F6864F2d406E8a0BB04964d4bc010a` |
| EscrowVault | `0xCdD50B2D88d17DB7D4E161a08185931031aBe3C0` |
| Tresori relayer | `0xB9CBD815098cc3d6A348bDfed995af91e2298d6D` |

**Admin:** `0xDb79cCBfFB614BCBf636a724D2E373cbAE36287d` (deployer; audit-remediation redeploy 2026-08-10)

---

## 2. IDs

```ts
import { keccak256, toUtf8Bytes, id } from "ethers";
import { createHash } from "crypto";

const GOLD = keccak256(toUtf8Bytes("GOLD"));
// 0xdbd17891fc491ac6717dd01ab1f90f82509f1f2e91cd5066f68805860fbdeb72

const SILVER = keccak256(toUtf8Bytes("SILVER"));
// 0x75e02a3ee626f5d4b8bc98cc8de5b102ee067608b6066832ffdc71f78445ac2b

const AP1 = keccak256(toUtf8Bytes("AP1")); // MMTC
// 0x18b117340645cfb38a7414f6a51f090965f4e22ead292d9dad633e05e91ff811
```

| | Value |
|--|--------|
| Provider | **MMTC** (`AP1`) |
| Operator | `0x77C1a84070bF6D4FF64602D467878EFC809C98DD` |
| Assets | GOLD, SILVER |

### Settlement ref hash (client-side)

Hash payment / payout / delivery refs with a server secret before sending on-chain. Secret never goes on-chain.

```ts
function hashSettlementRef(secret: string, plaintext: string): `0x${string}` {
  return `0x${createHash("sha256").update(secret + plaintext, "utf8").digest("hex")}`;
}
```

---

## 3. User onboarding

### Register (gasless)

`userId` must be **unique** across the platform (same off-chain user identity → same `userId`). Reusing a `userId` on another wallet reverts with `UserIdAlreadyUsed`.

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: WHITELIST_REGISTRY,
  functionName: "registerUserFor",
  params: [userWallet, id("user-123"), "KYC-REF"],
  abi: ["function registerUserFor(address wallet,bytes32 userId,string kycRef)"],
  fromAddress: userWallet,
  chain, clientShare, sessionId, rpcUrl,
});
```

### Verify KYC (gasless) — required for sell & redeem

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

Pending KYC users may **buy only** (lifetime non-KYC fiat cap is tracked by `userId`, not wallet). Sell/redeem need `isEligible(user) === true`.

---

## 4. Buy (gasless, instant)

No admin step. Status becomes `Executed` in the same tx.

```ts
const paymentRefHash = hashSettlementRef(SECRET, orderId);

const res = await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createBuyRequestFor",
  params: [userWallet, GOLD, AP1, weightUg, fiatValue, paymentRefHash, txDetailsHash],
  abi: [
    "function createBuyRequestFor(address,bytes32,bytes32,uint256,uint256,bytes32,bytes32) returns (uint256 requestId)",
  ],
  fromAddress: userWallet,
  chain, clientShare, sessionId, rpcUrl,
});

const requestId = res.result.decodedResult ?? BigInt(res.result.rawResult).toString();
```

**Reads after buy:**

```ts
await assetLedger.userHolding(userWallet, GOLD, AP1);
await assetLedger.tokenIdByBeneficiary(userWallet, GOLD);
await assetLedger.circulatingSupply(GOLD, AP1);
```

---

## 5. Sell

### Create (gasless) — no payout ref here

```ts
const res = await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createSellRequestFor",
  params: [userWallet, GOLD, AP1, amountUg],
  abi: [
    "function createSellRequestFor(address,bytes32,bytes32,uint256) returns (uint256 requestId)",
  ],
  fromAddress: userWallet,
  chain, clientShare, sessionId, rpcUrl,
});

const requestId = res.result.decodedResult ?? BigInt(res.result.rawResult).toString();
```

Requires KYC. Metal is escrow-locked. Status = `Proposed`.

### Admin execute (paid) — hashed payout ref

```ts
const settlementRef = hashSettlementRef(SECRET, payoutId);

await TreSori().writeMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "executeRequest",
  params: [requestId, settlementRef],
  abi: ["function executeRequest(uint256 requestId,bytes32 settlementRefId)"],
  fromAddress: adminWallet,
  rpcUrl, clientShare, sessionId,
});
```

### Cancel / reject

| Who | Function | Gasless? |
|-----|----------|----------|
| User | `cancelRequestFor(user, requestId)` | Yes |
| Admin | `rejectRequest(requestId, reason)` | No (paid) |

---

## 6. Redeem

Same pattern as sell. Amount must be ≥ `minRedeemAmountUg()` (default `10_000_000` µg = 10g).

### Create (gasless) — no delivery ref here

```ts
const res = await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createRedeemRequestFor",
  params: [userWallet, GOLD, AP1, amountUg],
  abi: [
    "function createRedeemRequestFor(address,bytes32,bytes32,uint256) returns (uint256 requestId)",
  ],
  fromAddress: userWallet,
  chain, clientShare, sessionId, rpcUrl,
});
```

### Admin execute (paid) — hashed delivery ref

```ts
await TreSori().writeMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "executeRequest",
  params: [requestId, hashSettlementRef(SECRET, deliveryId)],
  abi: ["function executeRequest(uint256 requestId,bytes32 settlementRefId)"],
  fromAddress: adminWallet,
  rpcUrl, clientShare, sessionId,
});
```

---

## 7. Useful reads

| What | Contract | Function |
|------|----------|----------|
| KYC / eligibility | WhitelistRegistry | `isEligible`, `isEligibleForNonKycUser`, `getProfile` |
| Balance | AssetLedger | `userHolding(user, assetId, providerId)` |
| Active provider | AssetLedger | `userActiveProvider(user, assetId)` |
| Circulating | AssetLedger | `circulatingSupply(assetId, providerId)`, `totalCirculating(assetId)` |
| Lifetime volume | AssetLedger | `lifetimeIssued`, `lifetimeSoldBack`, `lifetimeRedeemed` |
| Certificate NFT | AssetLedger | `tokenIdByBeneficiary(user, assetId)` |
| Request | TradeManager | `getRequest`, `getRequestStatus` |
| Min redeem | GovernanceConfig | `minRedeemAmountUg()` |

---

## 8. Flow order

```
1. User: registerUserFor → verifyKYCFor
2. User: createBuyRequestFor          → executed immediately
3. User: createSellRequestFor         → admin executeRequest(id, payoutHash)
4. User: createRedeemRequestFor       → admin executeRequest(id, deliveryHash)
```
