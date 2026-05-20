# Frontend Integration Guide

- Chain RPC and chain ID (example: Polygon Amoy `80002`).
- Contract addresses (redeploy and update after each release):
  - `TradeManager`
  - `GoldNFT`
  - `GovernanceConfig`
  - `WhitelistRegistry`
- Trusted forwarder on-chain must be set to Tresori gasless relayer/forwarder contract (`RELAYER_SMART_CONTRACT`).
- ABI JSON files under `abi/` (regenerate with `forge inspect src/<Contract>.sol:<Contract> abi --json`).
- Tresori SDK package: `@kalp_studio/tresori-sdk-js`.
- Tresori session values after user verification: `clientShare`, `sessionId`, `fromAddress`.

## 1) Required Inputs

Same as above; never hard-code stale proxy addresses from an old deployment.

## 2) Units and Encoding

- Gold amounts are **integer micrograms (µg)** on-chain.
- **`1 gram = 1_000_000 µg`**. Example: buy 1 g → pass `1000000` (or `"1000000"` as string).
- Display grams in UI: `grams = amountUg / 1_000_000` (align with `GovernanceConfig.goldPrecision()`, default `6`).
- Send large numeric values as strings in UI/backend payloads.
- `bytes32` must be `0x` + 64 hex chars.
- `TradeRequest` / `MintLotMeta` / events use field name **`amountUg`** (not `grams` or `weightMg`).

## 3) Read Endpoints for UI

Use direct contract reads:

- `WhitelistRegistry.getProfile(user)`
- `WhitelistRegistry.isEligible(user)`
- `WhitelistRegistry.isEligibleForNonKycUser(user)`
- `GovernanceConfig.minimumBuyGoldValueInUg()`
- `GovernanceConfig.maxAmountPerTx()`
- `GovernanceConfig.minRedeemAmountUg()`
- `GovernanceConfig.nonKycMaxBuyFiatAmount()`
- `GoldNFT.userHolding(user)` — balance in µg
- `GoldNFT.getUserLotIds(user)`
- `TradeManager.getUserRequests(user, offset, limit)`
- `TradeManager.getRequest(requestId)` — struct field `amountUg`
- `TradeManager.getRequestStatus(requestId)`

## 4) Gasless Write Pattern (All Operations)

For all user/operator writes, call Tresori SDK:

`writeGaslessMpcSmartContractTransaction(...)`

## 5) Operation Flows

Common call shape:

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "<contractFunction>",
  params: [/* function args */],
  abi: ["function <contractFunction>(...)"],
  fromAddress,   // MPC wallet address
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL
});
```

### Buy (user, gasless, auto-executed)

`createBuyRequest(uint256 weightUg,uint256 fiat_value,bytes32 payment_ref,bytes32 txDetailsHash)`

```ts
const weightUg = "1000000"; // 1 g
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createBuyRequest",
  params: [weightUg, fiatValue, paymentRef32, txDetailsHash32],
  abi: [
    "function createBuyRequest(uint256 weightUg,uint256 fiat_value,bytes32 payment_ref,bytes32 txDetailsHash)"
  ],
  fromAddress,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL
});
```

Expected: request is created and executed in the same transaction.

### Sell (user, gasless request creation)

`createSellRequest(uint256 amountUg,bytes32 payoutRefId)`

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createSellRequest",
  params: [amountUg, payoutRefId32],
  abi: ["function createSellRequest(uint256 amountUg,bytes32 payoutRefId)"],
  fromAddress,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL
});
```

Then track status until approvals + admin execution complete.

### Redeem (user, gasless request creation)

`createRedeemRequest(uint256 amountUg,bytes32 deliveryRefId)`

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createRedeemRequest",
  params: [amountUg, deliveryRefId32],
  abi: ["function createRedeemRequest(uint256 amountUg,bytes32 deliveryRefId)"],
  fromAddress,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL
});
```

### Mint (AP/operator, gasless proposal)

`proposeMint(uint256 amountUg,address creditTo,bytes32 vaultReceiptId,(bytes32,bytes32,uint16,uint256,address,address,uint256,uint256))`

- Tuple field order: `vaultReceiptId`, `batchId`, `purity`, `depositTimestamp`, `apId`, `vpId`, `lockUntilTs`, **`amountUg`**.
- Prefer **array** form for `params[3]` in the SDK, e.g. `[vaultReceiptId, batchId, purity, depositTs, apId, vpId, lockUntilTs, amountUg]`.
- `fromAddress` must hold `AP_ROLE` on `TradeManager`.

### Burn (AP/operator, gasless proposal)

`proposeBurn(uint256 amountUg,bytes32 referenceId,string reason_)`

Caller must be AP role wallet (`fromAddress`).

## 6) Role Requirements

- Buy/Sell/Redeem caller must have `USER_ROLE` on `TradeManager`.
- Mint/Burn caller must have `AP_ROLE` on `TradeManager`.
- Forwarder must be trusted by `TradeManager`, `WhitelistRegistry`, and `GoldNFT`.

## 7) Production Recommendations

- Never expose admin private keys in frontend.
- Validate user inputs against on-chain limits (`maxAmountPerTx`, caps, minimum buy) before sending gasless tx.
- Poll by tx hash and `getRequestStatus` for reliable UX.
- Keep ABI fragments in sync with deployed contract version (`abi/*.json`).

## 8) External Integration Package

Share with external integrators:

- This guide.
- Contract addresses for the current deployment.
- ABI JSON files.
- Chain RPC + chain ID.
- Required role model and function payload examples above.
