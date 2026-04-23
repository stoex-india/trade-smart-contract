# STOEX Gold — Smart contracts (Foundry)

UUPS upgradeable EVM implementation of the **STOEX India Gold NFT Technical PRD v2.0** (Polygon Amoy / EVM-compatible chains), including **ERC-2771 gasless transaction support** for selected operations.

## Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`, `anvil`)

## Quick commands

```shell
forge build
forge test -vv
```

## Repository layout

| Path | Purpose |
|------|---------|
| `src/` | Core contracts (`GovernanceConfig`, `WhitelistRegistry`, `GoldNFT`, `EscrowVault`, `TimelockController`, `TradeManager`) |
| `src/libraries/` | `StoexTypes`, `StoexRoles` |
| `src/interfaces/` | Integration interfaces |
| `script/DeployAmoy.s.sol` | Deploy all proxies + wire `TradeManager` / escrow / timelock |
| `script/ConfigureRoles.s.sol` | Grant AP/VP/AT/PAP/Auditor + optional `USER_ROLE` investors |
| `test/helpers/StoexFixture.sol` | Shared deployment for tests |
| `test/StoexPRD.t.sol` | PRD-mapped integration tests |
| `relayer/` | Configurable gasless relayer service (per-operation enable/disable + signer allowlists) |

---

## Step-by-step: environment → deploy → test → roles → operations

### 1) Install Foundry and clone

Install Foundry, then work in this package:

```shell
cd stoex-gold-contracts
cp .env.example .env
```

### 2) Configure `.env` for Amoy

Set at minimum:

- `AMOY_RPC_URL` — public or private RPC for Polygon Amoy.
- `PRIVATE_KEY` — **hex private key with `0x` prefix** (required by `vm.envUint` in this project scripts), e.g. `0xabc123...`. This deployer account becomes `DEFAULT_ADMIN_ROLE` on all contracts deployed by `DeployAmoy`.

Optional deploy tuning:

- `ASSET_PROVIDER_PAYOUT` — on-chain sink for sell escrow `releaseEscrow` (PRD routing).
- `REDEEM_SINK` — redeem release destination (e.g. burn / ops address).
- `VAULT_BOOKKEEPING` — whitelisted account whose `GoldNFT.userHolding` backs **burn** adjustments; fund it via normal buy/mint flows before burning.
- `FORWARDER_NAME` — EIP-712 domain name used by deployed `ERC2771Forwarder` (default: `STOEX Forwarder`).

### 3) Deploy to Amoy

Dry run (no transaction broadcast):

```shell
forge script script/DeployAmoy.s.sol:DeployAmoy --rpc-url amoy -vvv
```

Broadcast (sends transactions):

```shell
source .env
forge script script/DeployAmoy.s.sol:DeployAmoy --rpc-url $AMOY_RPC_URL --broadcast --verify
```

Copy from the console output into `.env`:

- `GOVERNANCE_CONFIG`
- `WHITELIST_REGISTRY`
- `GOLD_NFT`
- `ESCROW_VAULT` (not read by ConfigureRoles; keep for your records)
- `TIMELOCK_CONTROLLER`
- `TRADE_MANAGER`
- `ERC2771_FORWARDER`

`DeployAmoy` already: calls `setRoutingAddresses`, `setTradeManager` on escrow/timelock, grants `TRADE_MANAGER_ROLE` on `GoldNFT`.

### 4) Run automated tests (local)

Tests do **not** need Amoy; they deploy fresh proxies on the in-memory EVM:

```shell
forge test -vv
```

`StoexPRD.t.sol` covers buy/sell/redeem/mint/burn, escrow unlock paths, timelocks, co-signatures, governance, whitelist, and soulbound behavior.

### 5) Configure operational roles (`ConfigureRoles`)

Fill `.env` with proxy addresses and the **wallets** that should hold each role:

- `ROLE_AP`, `ROLE_VP`, `ROLE_AT`, `ROLE_PAP`, `ROLE_AUDITOR` (optional; use `0x0000…` or omit if your `vm.envOr` defaults apply — the script skips zero addresses).

Then:

```shell
forge script script/ConfigureRoles.s.sol:ConfigureRoles --rpc-url $AMOY_RPC_URL --broadcast
```

This grants:

- On **TradeManager**: AP, VP, AT, PAP, Auditor (as set).
- On **GoldNFT**: AP (for `mintCertificate`).
- On **TimelockController**: AP, AT (for timelock admin/override).
- On **GovernanceConfig** and **WhitelistRegistry**: AT (policy + trustee co-approval).

### 6) Onboard an investor (off-chain + on-chain)

For each investor wallet:

1. **Admin** calls `WhitelistRegistry.registerUser(userId, wallet, kycRef)`.
2. **Admin** calls `WhitelistRegistry.verifyKYC(wallet)` when KYC passes.
3. **Admin** grants **`USER_ROLE`** on **both** `WhitelistRegistry` and `TradeManager` (or add the wallet to `INVESTOR_1` … in `.env` and re-run `ConfigureRoles` after steps 1–2).

`USER_ROLE` on `TradeManager` is required for `createBuyRequest` / `createSellRequest` / `createRedeemRequest`.  
`USER_ROLE` on `WhitelistRegistry` is required for `requestWalletChange`.

### 7) Run operations (PRD flows)

All flows go through **TradeManager** unless noted.

| Flow | Who starts | Approval order (default) | Execution |
|------|------------|--------------------------|-----------|
| **Buy** | Investor (`createBuyRequest`) | AP → AT | `executeRequest` (admin) or `executeWithCoSignatures` |
| **Sell** | Investor (`createSellRequest`, escrow locks) | AP → AT | Admin execute |
| **Redeem** | Investor (`createRedeemRequest`) | AP → VP → PAP → AT | Admin execute |
| **Mint** | AP (`proposeMint`) | VP → AT | Admin execute |
| **Burn** | AP (`proposeBurn`) | VP → AT | Admin execute (debits `vaultBookkeeping`) |

**Admin executor** holds `DEFAULT_ADMIN_ROLE` on `TradeManager` and calls `executeRequest(requestId)` after status reaches fully approved (`ATApproved` in storage).

**EIP-712 co-sign**: integrators hash with `TradeManager.hashCoSignBatch(requestId, nonce, deadline)` using domain `StoexGoldTrade` / version `1`, then call `executeWithCoSignatures` (see tests in `StoexPRD.t.sol`).

**Direct certificate mint**: AP calls `GoldNFT.mintCertificate(user)` when you want a certificate before any trade execution.

### 8) Gasless (ERC-2771) setup

Contracts with trusted forwarder support in this repo:

- `TradeManager` (buy/sell/redeem/mint/burn and approvals)
- `WhitelistRegistry` (user/admin registry functions)
- `GoldNFT` (AP mint/admin operations)

`DeployAmoy` deploys an `ERC2771Forwarder` and wires it during contract initialization.

If you ever need to rotate forwarder:

1. Deploy a new forwarder contract.
2. Set `ERC2771_FORWARDER` in `.env`.
3. Run:

```shell
forge script script/ConfigureRoles.s.sol:ConfigureRoles --rpc-url $AMOY_RPC_URL --broadcast
```

The script will call:

- `TradeManager.setTrustedForwarder(...)`
- `WhitelistRegistry.setTrustedForwarder(...)`
- `GoldNFT.setTrustedForwarder(...)`

#### Relayer server (configurable operations)

1. Configure relayer env:

```shell
cd relayer
cp .env.example .env
```

Set:

- `RPC_URL`
- `RELAYER_PRIVATE_KEY`
- `ERC2771_FORWARDER`
- `OPERATIONS_CONFIG` (defaults to `./config/operations.example.json`)

2. Configure allowed gasless operations in `config/operations.example.json`:

- `enabled: true/false` per operation (turn gasless on/off anytime)
- `target` contract alias (`tradeManager`, `whitelistRegistry`, `goldNft`)
- ABI `fragment`
- `gas` limit
- optional `allowedSigners` whitelist for sensitive ops (mint/burn/admin)

3. Start server:

```shell
npm install
npm start
```

Endpoints:

- `GET /health`
- `GET /operations`
- `POST /typed-data` -> returns EIP-712 domain/types/message for wallet signing
- `POST /relay` -> verifies signature with forwarder and executes forwarded tx

Example flow for gasless `buy`:

1. Client calls `/typed-data` with:
   - `operation: "buy"`
   - `from: investor address`
   - `args: [grams, paymentRefId]`
2. Client signs returned typed data.
3. Client calls `/relay` with same payload + `signature`.
4. Relayer submits through `ERC2771Forwarder.execute`.

Operations can be enabled/disabled without redeploying contracts by changing relayer config and restarting relayer.

### 9) Useful `cast` examples

Read eligibility:

```shell
cast call $WHITELIST_REGISTRY "isEligible(address)(bool)" $INVESTOR_WALLET --rpc-url $AMOY_RPC_URL
```

Read holding:

```shell
cast call $GOLD_NFT "userHolding(address)(uint256)" $INVESTOR_WALLET --rpc-url $AMOY_RPC_URL
```

---

## NatSpec

Contracts under `src/` include file- and contract-level documentation describing roles, invariants, and how each module maps to the PRD.

## License

MIT (see SPDX headers in source files).
