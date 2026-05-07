# Frontend Integration Guide

- Chain RPC and chain ID (example: Polygon Amoy `80002`).
- Contract addresses:
  - `TradeManager` : 0x033a4fb16f07E7318eCb540C8f277fA84BD63539
  - `GoldNFT` : 0xe2E209fD325EEd51840275408D000E443192Fb3E
  - `GovernanceConfig` : 0x76516Ba8B030c829321140565825A8E27c1AfCe6
  - `WhitelistRegistry` : 0xE9870D9020CBD010392757817967C9c8695BB89E
  - `ERC2771Forwarder` : 0x0F8FCEe106fC27db8566Dd471A2b224B8339f7D4

- ABI JSON files for above contracts.
- Relayer base URL : Will share in separate doc.
- Relayer API Key : Will share in separate doc. 

## 2) Unit and Data Conventions

- Gold amounts are in mg (milligrams).
- Many API/contract numeric inputs should be sent as strings in JSON to avoid precision issues.
- `bytes32` values:
  - preferred format: hex string `0x` + 64 hex chars.
  - for human refs, backend can convert with `encodeBytes32String`.

## 3) Read-Only Data Needed for UI

Typical reads:

- `WhitelistRegistry.getProfile(user)` for eligibility/compliance state.
- `WhitelistRegistry.isEligible(user)` and `isEligibleForNonKycUser(user)`.
- `GovernanceConfig` limits:
  - `minimumBuyGoldValueInMg()`
  - `maxGramsPerTx()`
  - `minRedeemQuantity()`
  - `nonKycMaxBuyFiatAmount()`
- `GoldNFT.getUserHolding(user)` and `GoldNFT.getUserLotIds(user)`.
- `TradeManager.getUserRequests(user, offset, limit)` and `getRequest(requestId)`.

## 4) Gasless Meta-Tx Pattern (Common for User-Initiated Flows)

Use this for buy/sell/redeem and also for any relayer-configured op:

1. Call `POST /v1/meta-tx/typed-data` with `operation`, `from`, `args`.
2. User/MPC signs returned EIP-712 payload (`domain`, `types`, `message`).
3. Call `POST /v1/meta-tx/relay` with same payload + `signature`.
4. Poll tx hash and/or parse response `events.requestCreated`.

If your signer is an MPC wallet, it must support EIP-712 typed-data signature for the exact `ForwardRequest` struct. Let me know if this is not available in the SDK, i will check myself how can we resolve this. 

## 5) Flow-by-Flow Integration

## Buy Flow (Gasless, Auto-Executed)

Operation: `buy`  
Contract call: `TradeManager.createBuyRequest(weightMg, fiat_value, payment_ref, txDetailsHash)`

Frontend sequence:

1. Collect amount (`weightMg`) and fiat settlement metadata.
2. Optional preflight: `POST /v1/precheck/buy`.
3. Request typed data for `operation=buy`.
4. Sign typed data with user wallet/MPC.
5. Relay signature.
6. Mark success after relay tx mined and request status is executed.

Expected behavior:

- Buy executes in same transaction (no manual approvals/execution needed afterward).

---

## Sell Flow (Gasless Creation + Role Approvals + Execution)

Operation: `sell`  
Contract call at creation: `TradeManager.createSellRequest(grams, payoutRefId)`

Frontend sequence:

1. Collect sell amount and payout reference.
2. Optional preflight: `POST /v1/precheck/sell`.
3. Run typed-data -> sign -> relay.
4. Track created request ID.
5. Show request lifecycle from `TradeManager.getRequestStatus(requestId)` until executed/rejected/expired.

Expected backend/admin side:

- AP/AT role approvals and execution occur through operator tooling.

---

## Redeem Flow (Gasless Creation + Multi-Role Approvals + Execution)

Operation: `redeem`  
Contract call at creation: `TradeManager.createRedeemRequest(grams, deliveryRefId)`

Frontend sequence:

1. Collect redeem amount and delivery reference.
2. Optional preflight: `POST /v1/precheck/redeem`.
3. Run typed-data -> sign -> relay.
4. Track request status progression in UI.

Expected backend/admin side:

- Multi-role approval chain then execution.

---

## Mint Flow (Typically Operator Initiated)

Operation: `mint`  
Contract call: `TradeManager.proposeMint(grams, creditTo, vaultReceiptId, lot)`

Notes:

- Usually initiated by AP/operator signer, not retail user wallet.
- If your frontend has operator panel:
  - call typed-data for `mint`
  - sign with authorized operator wallet
  - relay and track request status.

---

## Burn Flow (Typically Operator Initiated)

Operation: `burn`  
Contract call: `TradeManager.proposeBurn(grams, referenceId, reason_)`

Notes:

- Similar to mint: initiated by authorized operator signer.
- Follow typed-data -> sign -> relay path and status tracking.

## 6) Request Status Tracking

Use:

- `TradeManager.getRequestStatus(requestId)` for compact status enum.
- `TradeManager.getRequest(requestId)` for full details.
- `TradeManager.getUserRequests(user, offset, limit)` for history UI.

Suggested UI statuses:

- Proposed / In Approval / Executed / Rejected / Cancelled / Expired.

## 7) Example Frontend Pseudocode (Meta-Tx)

```ts
const typed = await post("/v1/meta-tx/typed-data", {
  operation: "buy",
  from: userAddress,
  args: [weightMg, fiatValue, paymentRef32, txDetailsHash],
  deadlineSeconds: 900
});

const signature = await signer.signTypedData(
  typed.domain,
  typed.types,
  typed.message
);

const relayed = await post("/v1/meta-tx/relay", {
  operation: "buy",
  from: userAddress,
  args: [weightMg, fiatValue, paymentRef32, txDetailsHash],
  deadlineSeconds: 900,
  signature
});

console.log(relayed.txHash, relayed.events?.requestCreated?.requestId);
```

## 8) Security and Reliability Recommendations

- Never expose admin/operator private keys in frontend apps.
- Use relayer API key and strict CORS in production.
- Validate user input against on-chain policy limits before prompting signature.
- Add idempotency at frontend/backend orchestration layer for repeated button clicks.
- Poll chain confirmations and request status; do not assume mempool success.

## 9) What to Share with External Integrators

- This guide.
- Contract addresses and ABI files.
- Relayer API base URL and auth method.
- Supported operation list and exact arg schema from relayer `/v1/operations`.
