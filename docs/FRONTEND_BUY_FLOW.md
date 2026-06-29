# Buy Flow — User Gold Purchase

Registered user buys gold from the **AP pool** in **one gasless transaction**. No VP/AT approve and **no** admin `executeRequest`.

**Flow:** User `createBuyRequestFor` → gold credited immediately (`Executed`).

**Related:** onboarding → [FRONTEND_USER_ONBOARDING.md](./FRONTEND_USER_ONBOARDING.md) · AP pool funding → [FRONTEND_MINT_FLOW.md](./FRONTEND_MINT_FLOW.md)

---

## 1. Contract addresses (Amoy `80002`)

| Env key | Proxy | Buy use |
|---------|--------|---------|
| `TRADE_MANAGER` | `0x11c3048159305517ccEACEBA17531996148324aA` | `createBuyRequestFor` |
| `GOLD_NFT` | `0x8C26b220472AB8A8a1627087F3F2612768fA171D` | balance reads |
| `WHITELIST_REGISTRY` | `0x2A31A7b68418Ea301A6667fB7F1078170986EC98` | eligibility |
| `GOVERNANCE_CONFIG` | `0xEc2AaEE5BC7B7967A2c98F59072b9a376202A4a1` | caps, min buy |
| Tresori relayer | `0xB9CBD815098cc3d6A348bDfed995af91e2298d6D` | must match `trustedForwarder()` |

ABIs: `abi/TradeManager.abi.json`, `abi/GoldNFT.abi.json`, `abi/WhitelistRegistry.abi.json`

**Units:** `1 gram = 1_000_000` µg (`weightUg`).

---

## 2. What buy does

| On success (same tx) | Effect |
|----------------------|--------|
| `GoldNFT.userHolding(user)` | + `weightUg` |
| `totalAssetProviderBalance` | − `weightUg` |
| `circulatingSupply()` | + `weightUg` |
| `totalGoldSupply` | unchanged |
| Request status | **`5` (Executed)** immediately |

`requestType` for buy = **`0`**.

---

## 3. Preconditions (check before buy)

| Check | Read | Required |
|-------|------|----------|
| User registered | `WhitelistRegistry.getProfile(user)` | `registered == true` |
| `USER_ROLE` | `TradeManager.hasRole(USER_ROLE, user)` | `true` |
| Eligible | `isEligible(user)` **or** `isEligibleForNonKycUser(user)` | one `true` |
| AP pool depth | `GoldNFT.totalAssetProviderBalance()` | `>= weightUg` |
| Fiat (always) | `fiat_value` arg | `> 0` |
| Verified user | `isEligible(user)` | daily buy cap applies |
| Pending KYC user | `isEligibleForNonKycUser(user)` | cumulative `fiat_value` ≤ `nonKycMaxBuyFiatAmount()` |
| Min size | `GovernanceConfig.minimumBuyGoldValueInUg()` | `weightUg >= min` (if min > 0) |
| Per-tx cap | `GovernanceConfig.maxAmountPerTx()` | `weightUg <= max` |

**Sell / redeem** require verified KYC (`isEligible`). **Buy** works for pending KYC with fiat cap.

---

## 4. Single step — user buy (gasless)

**Contract:** `TradeManager`  
**Function:** `createBuyRequestFor(address user, uint256 weightUg, uint256 fiat_value, bytes32 payment_ref, bytes32 txDetailsHash)`

- `user` = investor MPC `fromAddress` (first param and signer).
- `fiat_value` = INR **minor units** (e.g. paise); used for non-KYC cap tracking.
- `payment_ref` / `txDetailsHash` = off-chain correlation / audit (`bytes32`, `0x` + 64 hex).

```ts
const weightUg = "1000000"; // 1 g
const fiatValue = "500000"; // example INR minor units — align with product
const paymentRef = "0x..."; // 32-byte payment id
const txDetailsHash = "0x..."; // 32-byte rails/settlement hash (or 0x00..00)

const result = await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createBuyRequestFor",
  params: [userMpcWallet, weightUg, fiatValue, paymentRef, txDetailsHash],
  abi: [
    "function createBuyRequestFor(address user,uint256 weightUg,uint256 fiat_value,bytes32 payment_ref,bytes32 txDetailsHash) returns (uint256 requestId)",
  ],
  fromAddress: userMpcWallet,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL,
});
```

**`requestId`:** use `result.decodedResult` when present; otherwise parse `RequestCreated` / `RequestExecuted` from the tx receipt (same Kalp `rawResult` caveat as mint).

**Do not** call `approveRequestFor` or `executeRequest` for buys — they revert (`BuyUsesAutoExecution`).

---

## 5. Verify buy — read calls (no gas)

```ts
// Request settled in same tx
const status = await sdk.readMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "getRequestStatus",
  params: [requestId],
  contractAbi: tradeManagerAbi,
  chain: selectedChain,
  rpcUrl: AMOY_RPC_URL,
});
// → "5" (Executed)

const holding = await sdk.readMpcSmartContractTransaction({
  contractAddress: GOLD_NFT,
  functionName: "userHolding",
  params: [userMpcWallet],
  contractAbi: goldAbi,
  chain: selectedChain,
  rpcUrl: AMOY_RPC_URL,
});
// increased by weightUg
```

### Cast

```bash
source .env

cast call $TRADE_MANAGER "getRequestStatus(uint256)(uint8)" <REQUEST_ID> --rpc-url $AMOY_RPC_URL
# → 5

cast call $GOLD_NFT "userHolding(address)(uint256)" <USER> --rpc-url $AMOY_RPC_URL
cast call $GOLD_NFT "totalAssetProviderBalance()(uint256)" --rpc-url $AMOY_RPC_URL
```

---

## 6. Buy complete checklist

| Check | Expected |
|-------|----------|
| `getRequestStatus(requestId)` | `5` (Executed) |
| `getRequest(requestId).requestType` | `0` (Buy) |
| `userHolding(user)` | increased by `weightUg` |
| `totalAssetProviderBalance` | decreased by `weightUg` |

---

## 7. Common errors

| Revert | Cause |
|--------|-------|
| `NotTrustedForwarder` | Non-gasless call or wrong `eth_call` `from` (use relayer for simulation) |
| `NotUser` | `USER_ROLE` not granted on `TradeManager` |
| `NotEligible` | Not registered or KYC rejected |
| `InsufficientApInventory` | `totalAssetProviderBalance < weightUg` — run mint flow first |
| `ZeroFiatValue` | `fiat_value == 0` |
| `CapBuy` | Verified user exceeded `dailyBuyCap` |
| `CapBuyNonKyc` | Pending KYC exceeded `nonKycMaxBuyFiatAmount` |
| `BelowMinBuyGold` | `weightUg` below `minimumBuyGoldValueInUg` |
| `ExceedsMax` | `weightUg > maxAmountPerTx` |

---

## Note

- Use **`writeGaslessMpcSmartContractTransaction`** only (not `writeMpcSmartContractTransaction`) for `createBuyRequestFor`.
- Payment settlement is off-chain; on-chain `fiat_value` and `payment_ref` are for caps and audit only.
