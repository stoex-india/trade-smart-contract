# Relayer API Reference (v1)

This document describes the production relayer endpoints available in `relayer/src/app.js`.

## Base URL

- Local: `http://127.0.0.1:8787`

All endpoints are prefixed with `/v1`.

## Auth
Every request must include:

- `x-api-key: <RELAYER_API_KEY>`
  or
- `Authorization: Bearer <RELAYER_API_KEY>`

## Standard Error Shape

```json
{
  "error": {
    "code": "ERROR_CODE",
    "message": "Human readable message",
    "details": {}
  }
}
```

`details` is optional.

---

## 1) Health and Metadata

### `GET /v1/health`

Returns relayer runtime and chain metadata.

Response:

```json
{
  "ok": true,
  "service": "stoex-gasless-relayer",
  "version": "1",
  "chainId": 80002,
  "blockNumber": 1234567,
  "relayer": "0x...",
  "forwarder": "0x...",
  "forwarderEip712Name": "STOEX Forwarder",
  "tradeManager": "0x...",
  "authRequired": true
}
```

---

## 2) Operations Registry

### `GET /v1/operations`

Returns operation config loaded from `OPERATIONS_CONFIG`.

Response example (shape):

```json
{
  "buy": {
    "enabled": true,
    "target": "tradeManager",
    "fragment": "function createBuyRequest(uint256 weightMg,uint256 fiat_value,bytes32 payment_ref,bytes32 txDetailsHash)",
    "gas": 700000
  }
}
```

---

## 3) Precheck Endpoints

Prechecks run read-only simulations and help fail fast before signature/relay.

### `POST /v1/precheck/buy`

Request:

```json
{
  "from": "0xUserAddress",
  "weightMg": "100000",
  "fiatValue": "1",
  "paymentRef": "BUY-REF-001",
  "txDetailsHash": "0x0000000000000000000000000000000000000000000000000000000000000000"
}
```

Success response:

```json
{
  "ok": true,
  "requestId": "42"
}
```

### `POST /v1/precheck/sell`

Request:

```json
{
  "from": "0xUserAddress",
  "grams": "500",
  "payoutRefId": "SELL-REF-001"
}
```

Success response:

```json
{
  "ok": true,
  "requestId": "43"
}
```

### `POST /v1/precheck/redeem`

Request:

```json
{
  "from": "0xUserAddress",
  "grams": "1000",
  "deliveryRefId": "REDEEM-REF-001"
}
```

Success response:

```json
{
  "ok": true,
  "requestId": "44"
}
```

### `POST /v1/precheck/raw`

Encodes operation calldata from configured ABI fragment.

Request:

```json
{
  "operation": "buy",
  "args": ["100000", "1", "0x...", "0x..."]
}
```

Success response:

```json
{
  "ok": true,
  "to": "0xTargetContract",
  "data": "0xEncodedCalldata"
}
```

---

## 4) Meta-Transaction Endpoints

These are the main gasless endpoints.

### `POST /v1/meta-tx/typed-data`

Builds ERC-2771 ForwardRequest typed data (EIP-712) for signing by user wallet/MPC.

Request:

```json
{
  "operation": "buy",
  "from": "0xUserAddress",
  "args": [
    "100000",
    "1",
    "0x0000000000000000000000000000000000000000000000000000000000000000",
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  ],
  "deadlineSeconds": 900
}
```

Success response:

```json
{
  "operation": "buy",
  "domain": {
    "name": "STOEX Forwarder",
    "version": "1",
    "chainId": 80002,
    "verifyingContract": "0xForwarder"
  },
  "types": {
    "ForwardRequest": [
      { "name": "from", "type": "address" },
      { "name": "to", "type": "address" },
      { "name": "value", "type": "uint256" },
      { "name": "gas", "type": "uint256" },
      { "name": "nonce", "type": "uint256" },
      { "name": "deadline", "type": "uint48" },
      { "name": "data", "type": "bytes" }
    ]
  },
  "message": {
    "from": "0xUserAddress",
    "to": "0xTradeManager",
    "value": "0",
    "gas": "700000",
    "nonce": "7",
    "deadline": "1715020000",
    "data": "0x..."
  },
  "meta": {
    "relayer": "0xRelayerEOA",
    "forwarder": "0xForwarder",
    "tradeManager": "0xTradeManager"
  }
}
```

### `POST /v1/meta-tx/relay`

Verifies signature via forwarder and submits transaction.

Request:

```json
{
  "operation": "buy",
  "from": "0xUserAddress",
  "args": [
    "100000",
    "1",
    "0x0000000000000000000000000000000000000000000000000000000000000000",
    "0x0000000000000000000000000000000000000000000000000000000000000000"
  ],
  "deadlineSeconds": 900,
  "signature": "0xUserEip712Signature"
}
```

Success response:

```json
{
  "ok": true,
  "txHash": "0x...",
  "blockNumber": 1234568,
  "operation": "buy",
  "events": {
    "forward": {
      "signer": "0xUserAddress",
      "nonce": "7",
      "success": true
    },
    "requestCreated": {
      "requestId": "42",
      "requestType": 0,
      "initiator": "0xUserAddress",
      "grams": "100000",
      "fiatValue": "1"
    }
  }
}
```

---

## Supported Operations and Args

Configured via `relayer/config/operations*.json`.

- `buy` -> `createBuyRequest(uint256 weightMg,uint256 fiat_value,bytes32 payment_ref,bytes32 txDetailsHash)`
- `sell` -> `createSellRequest(uint256 grams,bytes32 payoutRefId)`
- `redeem` -> `createRedeemRequest(uint256 grams,bytes32 deliveryRefId)`
- `mint` -> `proposeMint(uint256 grams,address creditTo,bytes32 vaultReceiptId,(...lot))`
- `burn` -> `proposeBurn(uint256 grams,bytes32 referenceId,string reason_)`

Important:
- `from` must match the signer address in EIP-712 signature.
- `args` must follow exact ABI fragment order and types.
- Bytes32 values must be 32-byte hex (`0x...` length 66) or encoded from trusted backend utilities.

---

## Relayer Environment Variables

Required:

- `PORT` (Railway can inject, default `8787`)
- `RPC_URL`
- `RELAYER_PRIVATE_KEY`
- `ERC2771_FORWARDER`
- `OPERATIONS_CONFIG` (path to operations JSON)

Recommended:

- `FORWARDER_EIP712_NAME` (must match deployed forwarder name)
- `FORWARDER_EIP712_VERSION` (usually `1`)
- `RELAYER_API_KEY`
- `TRUST_PROXY=true` (for Railway/proxy deployments)
- `CORS_ORIGIN=https://your-frontend.example.com`
- `RATE_LIMIT_WINDOW_MS`, `RATE_LIMIT_MAX`
