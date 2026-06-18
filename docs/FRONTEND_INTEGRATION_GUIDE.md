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

**Current Amoy proxies** (see also [FRONTEND_USER_ONBOARDING.md](./FRONTEND_USER_ONBOARDING.md)):

| Contract | Address |
|----------|---------|
| TradeManager | `0x11c3048159305517ccEACEBA17531996148324aA` |
| GoldNFT | `0x8C26b220472AB8A8a1627087F3F2612768fA171D` |
| GovernanceConfig | `0xEc2AaEE5BC7B7967A2c98F59072b9a376202A4a1` |
| WhitelistRegistry | `0x2A31A7b68418Ea301A6667fB7F1078170986EC98` |
| Tresori relayer | `0xB9CBD815098cc3d6A348bDfed995af91e2298d6D` |

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
- `GoldNFT.getPoolLotIds()` — AP inventory lots (mint path)
- `GoldNFT.totalAssetProviderBalance()` — AP buy pool depth
- `TradeManager.getRequest(requestId)` — struct field `amountUg`
- `TradeManager.getRequestStatus(requestId)`

## 4) Gasless Write Pattern (All Operations)

All user/operator writes use Tresori SDK `writeGaslessMpcSmartContractTransaction(...)`.

**Important:** Tresori relayer does **not** append ERC-2771 suffix bytes. Call **`functionName` ending in `For`** and pass the **wallet/actor as the first parameter**. Verify inner relay success, not only the outer tx hash.

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

`createBuyRequestFor(address user, uint256 weightUg, uint256 fiat_value, bytes32 payment_ref, bytes32 txDetailsHash)`

```ts
const weightUg = "1000000"; // 1 g
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createBuyRequestFor",
  params: [fromAddress, weightUg, fiatValue, paymentRef32, txDetailsHash32],
  abi: [
    "function createBuyRequestFor(address user,uint256 weightUg,uint256 fiat_value,bytes32 payment_ref,bytes32 txDetailsHash)"
  ],
  fromAddress,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL
});
```

### Sell (user, gasless request creation)

`createSellRequestFor(address user, uint256 amountUg, bytes32 payoutRefId)`

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createSellRequestFor",
  params: [fromAddress, amountUg, payoutRefId32],
  abi: ["function createSellRequestFor(address user,uint256 amountUg,bytes32 payoutRefId)"],
  fromAddress,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL
});
```

### Redeem (user, gasless request creation)

`createRedeemRequestFor(address user, uint256 amountUg, bytes32 deliveryRefId)`

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createRedeemRequestFor",
  params: [fromAddress, amountUg, deliveryRefId32],
  abi: ["function createRedeemRequestFor(address user,uint256 amountUg,bytes32 deliveryRefId)"],
  fromAddress,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL
});
```

### User onboarding (gasless)

See **[FRONTEND_USER_ONBOARDING.md](./FRONTEND_USER_ONBOARDING.md)**.

`registerUserFor(address wallet, bytes32 userId, string kycRef)` on **`WhitelistRegistry`**.

### Mint (AP/operator, gasless proposal)

Full step-by-step: **[FRONTEND_MINT_FLOW.md](./FRONTEND_MINT_FLOW.md)**.

`proposeMintFor(address ap, uint256 amountUg, bytes32 vaultReceiptId, MintLotMeta lot)`

### Burn (AP/operator, gasless proposal)

`proposeBurnFor(address ap, uint256 amountUg, bytes32 referenceId, string reason_)`

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
- [FRONTEND_USER_ONBOARDING.md](./FRONTEND_USER_ONBOARDING.md) — user onboarding flow.
- [FRONTEND_MINT_FLOW.md](./FRONTEND_MINT_FLOW.md) — mint / AP pool ops flow.
- Contract addresses for the current deployment.
- ABI JSON files.
- Chain RPC + chain ID.
- Required role model and function payload examples above.
