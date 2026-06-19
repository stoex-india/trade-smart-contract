# Mint Flow — AP Pool Funding

Load vaulted gold into the **AP buy pool** so registered users can buy. Mint is the only on-chain way to add retail inventory.

**Flow:** AP propose → VP approve → AT approve → admin execute.

**Gasless steps (1–3):** Tresori relayer + `*For` functions (explicit `ap` / `vp` / `at` as first param). **Step 4:** admin backend signs directly (not relayer).

**Related:** roles setup → [FRONTEND_ADMIN_ROLES.md](./FRONTEND_ADMIN_ROLES.md) · user buy → [FRONTEND_USER_ONBOARDING.md](./FRONTEND_USER_ONBOARDING.md)

---

## 1. Contract addresses (Amoy `80002`)

| Env key | Proxy | Mint use |
|---------|--------|----------|
| `TRADE_MANAGER` | `0x11c3048159305517ccEACEBA17531996148324aA` | propose, approve, execute |
| `GOLD_NFT` | `0x8C26b220472AB8A8a1627087F3F2612768fA171D` | pool balance reads |
| `GOVERNANCE_CONFIG` | `0xEc2AaEE5BC7B7967A2c98F59072b9a376202A4a1` | caps, VP toggle |
| Tresori relayer | `0xB9CBD815098cc3d6A348bDfed995af91e2298d6D` | must match `trustedForwarder()` |

ABIs: `abi/TradeManager.abi.json`, `abi/GoldNFT.abi.json`, `abi/GovernanceConfig.abi.json`

**Units:** `1 gram = 1_000_000` µg (`amountUg`).

---

## 2. What mint does

Mint credits the **AP pool**, not a user wallet.

| On `executeRequest` | Effect |
|---------------------|--------|
| `totalGoldSupply` | + `amountUg` |
| `totalAssetProviderBalance` | + `amountUg` |
| `userHolding[*]` | unchanged |
| `circulatingSupply()` | unchanged until users buy |

Buys debit `totalAssetProviderBalance` via `createBuyRequestFor`.

---

## 3. Approval sequence

| Step | Who | Function | Role on actor |
|------|-----|----------|---------------|
| 1 | AP | `proposeMintFor(ap, amountUg, vaultReceiptId, lot)` | `AP_ROLE` |
| 2 | VP | `approveRequestFor(vp, requestId)` | `VP_ROLE` |
| 3 | AT | `approveRequestFor(at, requestId)` | `AT_ROLE` |
| 4 | Admin | `executeRequest(requestId)` | `DEFAULT_ADMIN_ROLE` |

Default mint policy: **VP → AT**. If `GovernanceConfig.vpRequiredForApprovals()` is `false`, skip step 2.

### Request status (mint)

| Status | Value | Meaning |
|--------|-------|---------|
| `Proposed` | `0` | Awaiting first approval |
| `VPApproved` | `2` | VP done |
| `ATApproved` | `4` | Ready for admin execute |
| `Executed` | `5` | Pool funded |
| `Rejected` / `Expired` / `Cancelled` | `6` / `7` / `8` | Failed |

`requestType` for mint = **`3`**.

### Limits

| Policy | Typical default |
|--------|-----------------|
| `maxAmountPerTx` | `1_000_000_000` µg (1 kg) per propose |
| `requestExpiryDuration` | 7 days |

Chunk larger inventory into multiple mint requests.

---

## 4. Step 1 — AP propose (gasless)

**Contract:** `TradeManager`  
**Function:** `proposeMintFor(address ap, uint256 amountUg, bytes32 vaultReceiptId, MintLotMeta lot)`

`MintLotMeta` tuple order: `vaultReceiptId`, `batchId`, `purity`, `depositTimestamp`, `apId`, `vpId`, `lockUntilTs`, `amountUg`.

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "proposeMintFor",
  params: [
    apMpcWallet,
    amountUg,
    vaultReceiptId,
    [vaultReceiptId, batchId, purity, depositTs, apMpcWallet, vpMpcWallet, 0, amountUg],
  ],
  abi: [
    "function proposeMintFor(address ap,uint256 amountUg,bytes32 vaultReceiptId,tuple(bytes32 vaultReceiptId,bytes32 batchId,uint16 purity,uint256 depositTimestamp,address apId,address vpId,uint256 lockUntilTs,uint256 amountUg) lot) returns (uint256 requestId)",
  ],
  fromAddress: apMpcWallet,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL,
});
```

Save **`requestId`** from `RequestCreated` event (or `nextRequestId - 1` after tx). Check inner relay success.

---

## 5. Step 2 — VP approve (gasless)

Skip if `vpRequiredForApprovals()` is `false`.

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "approveRequestFor",
  params: [vpMpcWallet, requestId],
  abi: ["function approveRequestFor(address approver,uint256 requestId)"],
  fromAddress: vpMpcWallet,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL,
});
```

---

## 6. Step 3 — AT approve (gasless)

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "approveRequestFor",
  params: [atMpcWallet, requestId],
  abi: ["function approveRequestFor(address approver,uint256 requestId)"],
  fromAddress: atMpcWallet,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL,
});
```

After success: `getRequestStatus(requestId)` → **`4`** (`ATApproved`).

---

## 7. Step 4 — Admin execute (backend)

**Documented in admin panel:** [FRONTEND_ADMIN_ROLES.md](./FRONTEND_ADMIN_ROLES.md) §5.

Admin wallet with `DEFAULT_ADMIN_ROLE` on `TradeManager`. Call only when `getRequestStatus(requestId) === 4` (`ATApproved`).

```ts
await TreSori().writeMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "executeRequest",
  params: [requestId],
  abi: ["function executeRequest(uint256 requestId)"],
  fromAddress: adminWallet,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL,
});
```

After success: status **`5`** (`Executed`); pool balance increases.

---

## 8. Verify mint — read calls (no gas)

### Request settled

```ts
const trade = new Contract(TRADE_MANAGER, tradeAbi, provider);

const status = await trade.getRequestStatus(requestId);
// 5 = Executed

const req = await trade.getRequest(requestId);
// req.requestType === 3 (Mint)
// req.amountUg === minted amount
```

### Pool funded (buy readiness)

```ts
const gold = new Contract(GOLD_NFT, goldAbi, provider);

const poolBefore = ...; // snapshot before execute
const poolAfter = await gold.totalAssetProviderBalance();
const supply = await gold.totalGoldSupply();

// poolAfter === poolBefore + amountUg
// supply increased by same amountUg
// circulatingSupply unchanged if no user buys yet
```

### Optional lot metadata

```ts
const lotIds = await gold.getPoolLotIds();
const lot = await gold.getMintLot(lotIds[lotIds.length - 1]);
```

### Pre-flight policy reads

```ts
const gov = new Contract(GOVERNANCE_CONFIG, govAbi, provider);
const maxPerTx = await gov.maxAmountPerTx();
const vpRequired = await gov.vpRequiredForApprovals();
```

---

## 9. Mint complete checklist

| Check | Expected |
|-------|----------|
| `getRequestStatus(requestId)` | `5` (Executed) |
| `getRequest(requestId).requestType` | `3` (Mint) |
| `totalAssetProviderBalance` | increased by `amountUg` |
| `totalGoldSupply` | increased by `amountUg` |
| `routingConfigured()` on TradeManager | `true` |
| AP / VP / AT roles granted | see [admin roles doc](./FRONTEND_ADMIN_ROLES.md) |

**Users can buy when:**

1. Onboarding checks pass ([onboarding doc](./FRONTEND_USER_ONBOARDING.md))
2. `totalAssetProviderBalance >=` buy `weightUg`

---

## 10. Events to index

| Event | Contract |
|-------|----------|
| `RequestCreated(requestId, requestType, initiator, amountUg, fiatValue)` | TradeManager — `requestType = 3` |
| `RequestApproved(requestId, role, approver)` | TradeManager |
| `RequestExecuted(requestId, requestType)` | TradeManager |
| `UserRegistered` | WhitelistRegistry — unrelated; for user index |

---

## 11. Common errors

| Revert | Cause |
|--------|-------|
| `NotTrustedForwarder` | `*For` call not relayed by configured relayer |
| `NotApprover` | Approver wallet lacks next policy role |
| `NotFullyApproved` | `executeRequest` before AT approval |
| `ExceedsMax` | `amountUg > maxAmountPerTx` |
| `Expired` | Approval after request `expiresAt` |
| `AccessControlUnauthorizedAccount` | Admin execute without `DEFAULT_ADMIN_ROLE` |

---

## Note

Role grants (`AP_ROLE`, etc.) are done from the admin panel first — [FRONTEND_ADMIN_ROLES.md](./FRONTEND_ADMIN_ROLES.md). Mint ops wallets only need the relayer for steps 1–3; admin execute is a separate direct-signed tx.
