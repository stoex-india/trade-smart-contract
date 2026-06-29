# Reject Request — Ops Integration

Stop a pending **Mint / Burn / Sell / Redeem** request before admin execute. Does **not** apply to **Buy** (buys auto-execute).

**Related:** mint flow → [FRONTEND_MINT_FLOW.md](./FRONTEND_MINT_FLOW.md) · admin execute → [FRONTEND_ADMIN_ROLES.md](./FRONTEND_ADMIN_ROLES.md)

---

## 1. Contract & function

| Item | Value |
|------|--------|
| Contract | `TradeManager` — `0x11c3048159305517ccEACEBA17531996148324aA` |
| Function | `rejectRequestFor(address rejector, uint256 requestId, string reason)` |
| Call type | **Gasless** via Tresori relayer (`onlyTrustedForwarder`) |
| ABI | `abi/TradeManager.abi.json` |

---

## 2. Who can reject

`rejector` must hold **at least one** of these roles on `TradeManager`:

- `AP_ROLE`
- `VP_ROLE`
- `AT_ROLE`
- `PAP_ROLE`

**Admin (`DEFAULT_ADMIN_ROLE`) cannot call `rejectRequestFor`.** Admin blocks execution by not calling `executeRequest`.

---

## 3. When rejection is allowed

Request must still be **pending** (not Executed / Rejected / Cancelled / Expired).

Typical use: mint at `Proposed` or `VPApproved`, sell/redeem mid-approval, before status reaches `ATApproved` (4).

---

## 4. SDK example (gasless)

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "rejectRequestFor",
  params: [atMpcWallet, requestId, "Compliance hold"],
  abi: ["function rejectRequestFor(address rejector,uint256 requestId,string reason)"],
  fromAddress: atMpcWallet,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL,
});
```

- `rejector` = first param (wallet with AP/VP/AT/PAP role)
- `fromAddress` = same MPC wallet
- Check **inner relay success**, not only outer tx hash

---

## 5. What happens on-chain

| Request type | Escrow? | On reject |
|--------------|---------|-----------|
| **Mint / Burn** | No | Status → **`Rejected` (6)**. No pool/supply change. |
| **Sell / Redeem** | Yes | Escrow **unlocked**; user gold returned. Status → **`Rejected` (6)**. |

Event: `RequestRejected(requestId, role, rejector, reason)`

To retry → new propose flow (`proposeMintFor`, `createSellRequestFor`, etc.) with a **new** `requestId`.

---

## 6. Verify rejection (read, no gas)

```ts
const trade = new Contract(TRADE_MANAGER, tradeAbi, provider);

const status = await trade.getRequestStatus(requestId);
// 6 = Rejected

const req = await trade.getRequest(requestId);
// inspect requestType, amountUg, reason field if needed
```

**Mint:** `GoldNFT.totalAssetProviderBalance()` unchanged.

**Sell / Redeem:** `escrow.getLockedAmount(user)` → `0` for that request.

---

## 7. Reject vs cancel vs admin non-execute

| Action | Who | Function |
|--------|-----|----------|
| **Reject** | AP / VP / AT / PAP | `rejectRequestFor(rejector, requestId, reason)` |
| **Cancel** | Request initiator only | `cancelRequestFor(initiator, requestId)` |
| **Expire** | Anyone, after deadline | `expireRequest(requestId)` |
| **Admin block** | Admin | Do **not** call `executeRequest` |

---

## 8. Common errors

| Revert | Cause |
|--------|-------|
| `NotTrustedForwarder` | Not relayed through configured relayer |
| `NotApprover` | `rejector` lacks AP/VP/AT/PAP on TradeManager |
| `BadStatus` | Request already terminal (executed, rejected, etc.) |

---

## 9. Mint example (AT rejects)

```
proposeMintFor     →  Proposed (0)
approveRequestFor (VP) →  VPApproved (2)   [if VP required]
rejectRequestFor (AT)  →  Rejected (6)   ← stops here
executeRequest     →  not possible
```

Pool balance unchanged. Submit a new `proposeMintFor` to mint again.
