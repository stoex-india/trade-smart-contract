# Frontend Integration Guide

- Chain RPC and chain ID (example: Polygon Amoy `80002`).
- Contract addresses:
  - `TradeManager` : 0x033a4fb16f07E7318eCb540C8f277fA84BD63539
  - `GoldNFT` : 0xe2E209fD325EEd51840275408D000E443192Fb3E
  - `GovernanceConfig` : 0x76516Ba8B030c829321140565825A8E27c1AfCe6
  - `WhitelistRegistry` : 0xE9870D9020CBD010392757817967C9c8695BB89E

## 1) Required Inputs

- Chain RPC and chain ID (Polygon Amoy: `80002`).
- Contract addresses:
  - `TradeManager`
  - `GoldNFT`
  - `GovernanceConfig`
  - `WhitelistRegistry`
- Trusted forwarder on-chain must be set to Tresori gasless relayer/forwarder contract (`RELAYER_SMART_CONTRACT`).
- ABI JSON files for all above contracts.
- Tresori SDK package: `@kalp_studio/tresori-sdk-js`.
- Tresori session values after user verification: `clientShare`, `sessionId`, `fromAddress`.

## 2) Units and Encoding

- Gold amounts are integer milligrams (mg).
- Send large numeric values as strings in UI/backend payloads.
- `bytes32` must be `0x` + 64 hex chars.

## 3) Read Endpoints for UI

Use direct contract reads:

- `WhitelistRegistry.getProfile(user)`
- `WhitelistRegistry.isEligible(user)`
- `WhitelistRegistry.isEligibleForNonKycUser(user)`
- `GovernanceConfig.minimumBuyGoldValueInMg()`
- `GovernanceConfig.maxGramsPerTx()`
- `GovernanceConfig.minRedeemQuantity()`
- `GovernanceConfig.nonKycMaxBuyFiatAmount()`
- `GoldNFT.getUserHolding(user)`
- `GoldNFT.getUserLotIds(user)`
- `TradeManager.getUserRequests(user, offset, limit)`
- `TradeManager.getRequest(requestId)`
- `TradeManager.getRequestStatus(requestId)`

## 4) Gasless Write Pattern (All Operations)

For all user/operator writes, call Tresori SDK:

`writeGaslessMpcSmartContractTransaction(...)`

## 5) Flow-by-Flow Integration

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

## 5) Operation Flows

## Buy (user, gasless, auto-executed)

Contract function:

`createBuyRequest(uint256 weightMg,uint256 fiat_value,bytes32 payment_ref,bytes32 txDetailsHash)`

SDK invocation:

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createBuyRequest",
  params: [weightMg, fiatValue, paymentRef32, txDetailsHash32],
  abi: [
    "function createBuyRequest(uint256 weightMg,uint256 fiat_value,bytes32 payment_ref,bytes32 txDetailsHash)"
  ],
  fromAddress,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL
});
```

Expected: request is created and executed in same tx.

## Sell (user, gasless request creation)

Function: `createSellRequest(uint256 grams,bytes32 payoutRefId)`

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createSellRequest",
  params: [grams, payoutRefId32],
  abi: ["function createSellRequest(uint256 grams,bytes32 payoutRefId)"],
  fromAddress,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL
});
```

Then track status until approvals + admin execution complete.

## Redeem (user, gasless request creation)

Function: `createRedeemRequest(uint256 grams,bytes32 deliveryRefId)`

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createRedeemRequest",
  params: [grams, deliveryRefId32],
  abi: ["function createRedeemRequest(uint256 grams,bytes32 deliveryRefId)"],
  fromAddress,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL
});
```

Then track status until approvals + admin execution complete.

## Mint (AP/operator, gasless proposal)

Function: `proposeMint(uint256,address,bytes32,(bytes32,bytes32,uint16,uint256,address,address,uint256,uint256))`

Caller must be AP role wallet (`fromAddress`).

## Burn (AP/operator, gasless proposal)

Function: `proposeBurn(uint256,bytes32,string)`

Caller must be AP role wallet (`fromAddress`).

## 6) Role Requirements

- Buy/Sell/Redeem caller must have `USER_ROLE` on `TradeManager`.
- Mint/Burn caller must have `AP_ROLE` on `TradeManager`.
- Forwarder must be trusted by `TradeManager`, `WhitelistRegistry`, and `GoldNFT`.

## 7) Production Recommendations

- Never expose admin private keys in frontend.
- Validate user inputs against on-chain limits before sending gasless tx.
- Poll by tx hash and `getRequestStatus` for reliable UX.
- Keep ABI fragments in sync with deployed contract version.

## 8) External Integration Package

Share with external integrators:

- This guide.
- Contract addresses.
- ABI JSON files.
- Chain RPC + chain ID.
- Required role model and function payload examples above.
