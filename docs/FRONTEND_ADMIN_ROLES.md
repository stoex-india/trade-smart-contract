# Admin Panel — Roles & Admin Transfer

Configure **AP / VP / AT** ops wallets, **execute approved trade requests**, and rotate **platform admin** on Polygon Amoy.

**Who signs:** wallet with `DEFAULT_ADMIN_ROLE` on each target contract — **secure admin backend only**, not the user app and not the Tresori relayer.

**Related:** user onboarding → [FRONTEND_USER_ONBOARDING.md](./FRONTEND_USER_ONBOARDING.md) · mint → [FRONTEND_MINT_FLOW.md](./FRONTEND_MINT_FLOW.md)

---

## 1. Contract addresses (Amoy `80002`)

| Env key | Proxy |
|---------|--------|
| `GOVERNANCE_CONFIG` | `0xEc2AaEE5BC7B7967A2c98F59072b9a376202A4a1` |
| `WHITELIST_REGISTRY` | `0x2A31A7b68418Ea301A6667fB7F1078170986EC98` |
| `GOLD_NFT` | `0x8C26b220472AB8A8a1627087F3F2612768fA171D` |
| `ESCROW_VAULT` | `0x0E4e5bb30162104736F0a718984fa48DFBB383C2` |
| `TIMELOCK_CONTROLLER` | `0xF12b3226abeb60930C5Ae9aB86846FE1cc5FBd41` |
| `TRADE_MANAGER` | `0x11c3048159305517ccEACEBA17531996148324aA` |

ABIs: `abi/TradeManager.abi.json`, `abi/GovernanceConfig.abi.json`, `abi/WhitelistRegistry.abi.json`, `abi/GoldNFT.abi.json`, `abi/TimelockController.abi.json`

---

## 2. Role identifiers

All roles are `bytes32`. In TypeScript:

```ts
import { id } from "ethers";

const DEFAULT_ADMIN_ROLE = "0x0000000000000000000000000000000000000000000000000000000000000000";
const AP_ROLE  = id("AP_ROLE");
const VP_ROLE  = id("VP_ROLE");
const AT_ROLE  = id("AT_ROLE");
const PAP_ROLE = id("PAP_ROLE"); // redeem approvals only — optional
```

| Role | Used for |
|------|----------|
| `AP_ROLE` | Mint/burn propose, sell/redeem approvals, `GoldNFT.mintCertificate` |
| `VP_ROLE` | Mint/burn/redeem approvals (when VP enabled) |
| `AT_ROLE` | Final approvals, governance policy updates, wallet-change co-sign |
| `DEFAULT_ADMIN_ROLE` | `grantRole`, `verifyKYC`, `executeRequest`, upgrades, `transferAdmin` |

---

## 3. Grant ops roles — which contracts to call

Call **`grantRole(bytes32 role, address account)`** on each row below. Caller must hold **`DEFAULT_ADMIN_ROLE`** on that same contract.

| Grant | Contracts (call `grantRole` on each) |
|-------|--------------------------------------|
| **AP** → `wallet` | `TradeManager`, `GoldNFT`, `TimelockController` |
| **VP** → `wallet` | `TradeManager` only |
| **AT** → `wallet` | `TradeManager`, `GovernanceConfig`, `WhitelistRegistry`, `TimelockController` |
| **PAP** → `wallet` (optional) | `TradeManager` only |

To remove access later: `revokeRole(bytes32 role, address account)` on the same contracts.

---

## 4. Admin panel write — SDK example

Use your admin MPC / custodial signer (same stack as `verifyKYC`). Example shape with Tresori (admin pays gas; **not** relayer `*For`):

```ts
async function grantApRole(apWallet: string) {
  const role = id("AP_ROLE");
  const contracts = [TRADE_MANAGER, GOLD_NFT, TIMELOCK_CONTROLLER];

  for (const contractAddress of contracts) {
    await TreSori().writeMpcSmartContractTransaction({
      contractAddress,
      functionName: "grantRole",
      params: [role, apWallet],
      abi: ["function grantRole(bytes32 role, address account)"],
      fromAddress: ADMIN_WALLET,
      chain: selectedChain,
      clientShare,
      sessionId,
      rpcUrl: AMOY_RPC_URL,
    });
  }
}
```

**VP** — one call on `TradeManager` with `VP_ROLE`.

**AT** — four calls: `TradeManager`, `GovernanceConfig`, `WhitelistRegistry`, `TimelockController` with `AT_ROLE`.

After each tx, verify with `hasRole` (§7).

---

## 5. Execute approved trade requests

Final settlement step for **Mint, Burn, Sell, and Redeem** after ops wallets complete gasless approvals (`approveRequestFor`). **Buy does not use this** — buys auto-execute in `createBuyRequestFor`.

| Item | Value |
|------|--------|
| Contract | `TradeManager` (`0x11c3048159305517ccEACEBA17531996148324aA`) |
| Function | `executeRequest(uint256 requestId)` |
| Signer | Admin wallet with `DEFAULT_ADMIN_ROLE` on **TradeManager** |
| Call type | Direct admin-signed tx (**not** relayer `*For`) |

### When to enable the button

Read `getRequestStatus(requestId)` first:

| Status | Value | Admin can execute? |
|--------|-------|-------------------|
| `ATApproved` | `4` | **Yes** |
| `Executed` | `5` | No — already done |
| `Proposed` / `VPApproved` | `0` / `2` | No — approvals pending |
| `Rejected` / `Expired` / `Cancelled` | `6` / `7` / `8` | No |

### SDK example

Same pattern as `verifyKYC` and `grantRole` — admin MPC / backend signer:

```ts
await TreSori().writeMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "executeRequest",
  params: [requestId],
  abi: ["function executeRequest(uint256 requestId)"],
  fromAddress: ADMIN_WALLET,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL,
});
```

### Verify execution (read, no gas)

```ts
const trade = new Contract(TRADE_MANAGER, tradeAbi, provider);

const status = await trade.getRequestStatus(requestId);
// 5 = Executed

const req = await trade.getRequest(requestId);
// req.requestType: 0=Buy, 1=Sell, 2=Redeem, 3=Mint, 4=Burn
// req.amountUg: settled amount
```

**Mint-specific:** after execute, `GoldNFT.totalAssetProviderBalance()` increases by `amountUg`. See [FRONTEND_MINT_FLOW.md](./FRONTEND_MINT_FLOW.md) for full mint verification.

**Sell / Redeem:** escrow releases and user gold balance updates on execute.

Event: `RequestExecuted(requestId, requestType)`.

---

## 6. Transfer platform admin

`transferAdmin(address newAdmin)` rotates **`DEFAULT_ADMIN_ROLE`** on one proxy. The **current admin** must sign; `newAdmin` receives admin, caller loses it.

**Important:** run on **all six** proxies (same `newAdmin` each time):

1. `GovernanceConfig`
2. `WhitelistRegistry`
3. `GoldNFT`
4. `EscrowVault`
5. `TimelockController`
6. `TradeManager`

```ts
const PROXIES = [
  GOVERNANCE_CONFIG,
  WHITELIST_REGISTRY,
  GOLD_NFT,
  ESCROW_VAULT,
  TIMELOCK_CONTROLLER,
  TRADE_MANAGER,
];

for (const contractAddress of PROXIES) {
  await TreSori().writeMpcSmartContractTransaction({
    contractAddress,
    functionName: "transferAdmin",
    params: [newAdminWallet],
    abi: ["function transferAdmin(address newAdmin)"],
    fromAddress: currentAdminWallet,
    chain: selectedChain,
    clientShare,
    sessionId,
    rpcUrl: AMOY_RPC_URL,
  });
}
```

Event to index: `AdminTransferred(previousAdmin, newAdmin)`.

---

## 7. Verify role — read calls (no gas)

**Function (all AccessControl proxies):**

```solidity
hasRole(bytes32 role, address account) → bool
```

### TypeScript — single role

```ts
const trade = new Contract(TRADE_MANAGER, tradeAbi, provider);
const ok = await trade.hasRole(id("AP_ROLE"), wallet);
```

### TypeScript — full AP grant check

```ts
const contracts = [TRADE_MANAGER, GOLD_NFT, TIMELOCK_CONTROLLER];
const results = await Promise.all(
  contracts.map((addr) => new Contract(addr, abi, provider).hasRole(id("AP_ROLE"), wallet))
);
const apReady = results.every(Boolean);
```

### TypeScript — full AT grant check

```ts
const contracts = [TRADE_MANAGER, GOVERNANCE_CONFIG, WHITELIST_REGISTRY, TIMELOCK_CONTROLLER];
const atReady = (await Promise.all(
  contracts.map((addr) => new Contract(addr, abi, provider).hasRole(id("AT_ROLE"), wallet))
)).every(Boolean);
```

---

## 8. Admin panel checklist

**Grant AP**

- [ ] `grantRole(AP_ROLE, wallet)` on TradeManager, GoldNFT, TimelockController
- [ ] All three `hasRole(AP_ROLE, wallet)` → `true`

**Grant VP**

- [ ] `grantRole(VP_ROLE, wallet)` on TradeManager
- [ ] `hasRole(VP_ROLE, wallet)` on TradeManager → `true`

**Grant AT**

- [ ] `grantRole(AT_ROLE, wallet)` on TradeManager, GovernanceConfig, WhitelistRegistry, TimelockController
- [ ] All four `hasRole(AT_ROLE, wallet)` → `true`

**Execute request (mint / burn / sell / redeem)**

- [ ] `getRequestStatus(requestId)` → `4` (`ATApproved`)
- [ ] `executeRequest(requestId)` on TradeManager signed by admin
- [ ] `getRequestStatus(requestId)` → `5` (`Executed`)

**Transfer admin**

- [ ] `transferAdmin(newAdmin)` on all six proxies
- [ ] Old admin `hasRole(DEFAULT_ADMIN_ROLE)` → `false`; new admin → `true` on each proxy

---

## 9. Common errors

| Error | Meaning |
|-------|---------|
| `AccessControlUnauthorizedAccount` | Signer is not `DEFAULT_ADMIN_ROLE` on this contract |
| `NotFullyApproved` | `executeRequest` before status is `ATApproved` (`4`) |
| `BuyUsesAutoExecution` | `executeRequest` called on a Buy request (not allowed) |
| `BadStatus` | Request already executed, rejected, or cancelled |
| `AdminNotInitialized` | `transferAdmin` before `setInitialAdmin` (deploy-only) |
| `DeployerZeroAddress` | `transferAdmin(0x0)` not allowed |

---

## Note on gasless ops

Mint/approve use relayer `*For` functions — [FRONTEND_MINT_FLOW.md](./FRONTEND_MINT_FLOW.md). **Role grants, `executeRequest`, and admin transfer** are direct admin-signed txs, not relayer-gated.
