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
| `src/base/` | `StoexDeployerAdminUpgradeable` — deployer → initial admin handoff + `transferAdmin` |
| `src/libraries/` | `StoexTypes`, `StoexRoles` |
| `src/interfaces/` | Integration interfaces |
| `script/DeployAmoy.s.sol` | Deploy all proxies; deployer calls `setInitialAdmin`; wires routing if deployer == admin |
| `script/WireProxiesAdmin.s.sol` | Admin-only: `setRoutingAddresses`, `setTradeManager`, `TRADE_MANAGER_ROLE` when admin ≠ deployer |
| `script/SetInitialAdmins.s.sol` | Optional: deployer calls `setInitialAdmin` on all proxies (if not done in deploy tx) |
| `script/GovernanceAdminFlags.s.sol` | Admin toggles `GovernanceConfig.vpRequiredForApprovals` |
| `script/ConfigureRoles.s.sol` | Grant AP/VP/AT/PAP/Auditor + optional forwarder rotation (**admin** key) |
| `script/OnboardInvestors.s.sol` | Register + verify KYC + grant `USER_ROLE` for `INVESTOR_1..20` |
| `script/BuyFlow.s.sol` | Buy request lifecycle (USER -> AP -> AT -> ADMIN execute) |
| `script/SellFlow.s.sol` | Sell request lifecycle (USER -> AP -> AT -> ADMIN execute) |
| `script/RedeemFlow.s.sol` | Redeem lifecycle (USER -> AP -> VP -> PAP -> AT -> ADMIN execute) |
| `script/MintFlow.s.sol` | Mint lifecycle (AP -> VP -> AT -> ADMIN execute) |
| `script/BurnFlow.s.sol` | Burn lifecycle (AP -> VP -> AT -> ADMIN execute) |
| `test/helpers/StoexFixture.sol` | Shared deployment for tests |
| `test/StoexPRD.t.sol` | PRD-mapped integration tests |
| `relayer/` | Configurable gasless relayer service (per-operation enable/disable + signer allowlists) |
| `relayer/src/gasless-runner.js` | End-to-end gasless operation runner (optional parallel mode) |

---

## Step-by-step: environment → deploy → test → roles → operations

### Deployer vs operations admin (RBAC)

- **Deployer** (`deployer` on-chain): the wallet passed into each contract’s `initialize`. It has **no** `DEFAULT_ADMIN_ROLE` after deployment. It may call **`setInitialAdmin(admin)` exactly once** per proxy to grant the operations admin.
- **Admin** (`DEFAULT_ADMIN_ROLE`): pauses, upgrades (UUPS), `TradeManager.executeRequest`, forwarder rotation, `GovernanceConfig.setVpRequiredForApprovals`, registry KYC, etc. Admins rotate with **`transferAdmin(newAdmin)`** (callable only by the current admin, on each contract where rotation is needed).
- **Asset Trustee (`AT_ROLE`)** still updates economic policy on `GovernanceConfig` (caps, approval *matrices*, `nonKycMaxHoldingCap`, etc.). **VP on/off** is admin-only and implemented by filtering `VP_ROLE` out of the *effective* approval path for Redeem / Mint / Burn when disabled (see `getApprovalPolicy`).

### KYC tiers (buy vs full access)

- **`registerUser`** creates a **Pending** KYC profile. **`isEligibleForRestrictedBuy`** is true for Pending users (whitelisted wallet, active, within risk rules). They may **`createBuyRequest` only**, using a configurable **max total holding cap** **`GovernanceConfig.nonKycMaxHoldingCap`** (Asset Trustee adjusts via **`setNonKycMaxHoldingCap`**). Enforcement is `current userHolding + buy grams <= cap`.
- **`verifyKYC`** (admin) moves a user to **Verified** → **`isEligible`** is true → sell, redeem, full daily buy cap (`dailyBuyCap`), mint/burn bookkeeping paths, nominee transfer, etc., as before.
- **`rejectKYC`** users are not eligible for restricted buy.

### 1) Install Foundry and clone

Install Foundry, then work in this package:

```shell
cd stoex-gold-contracts
cp .env.example .env
```

### 2) Configure `.env` for Amoy

Set at minimum:

- `AMOY_RPC_URL` — public or private RPC for Polygon Amoy.
- `PRIVATE_KEY` — **deployer** key (`0x…`, for `vm.envUint` in scripts). This wallet is stored as `deployer` on new proxies; it is **not** the admin until you point it at the same address as `INITIAL_ADMIN` and complete the handoff (see below).
- `INITIAL_ADMIN` — **operations admin** `0x…` address receiving `DEFAULT_ADMIN_ROLE` via `setInitialAdmin` (defaults to the deployer address if unset).

Optional deploy tuning:

- `ASSET_PROVIDER_PAYOUT` — on-chain sink for sell escrow `releaseEscrow` (PRD routing); defaults to **`INITIAL_ADMIN`** when deployer wires in-script.
- `REDEEM_SINK` — redeem release destination (e.g. burn / ops address).
- `VAULT_BOOKKEEPING` — whitelisted account whose `GoldNFT.userHolding` backs **burn** adjustments; fund it via normal buy/mint flows before burning (defaults to **`INITIAL_ADMIN`** when wired in-script).
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

**If broadcast flakes:** Public RPCs often drop transactions from the mempool when the fee is tight or the endpoint is busy. You may see `dropped from the mempool` and, on Foundry 1.5.x, a crash (`attempt to divide by zero` in `broadcast.rs`) — that is a [known Foundry bug](https://github.com/foundry-rs/foundry/issues/13507) when receipts are missing, not a fault in this repo. Mitigations:

1. **Send slowly** (one tx at a time, waits for receipts): add `--slow`.
2. **Raise fees** so txs are not evicted: e.g. `--gas-estimate-multiplier 130` and/or `--priority-gas-price 35gwei` (tune to current Amoy conditions).
3. **Resume** after a partial run: rerun the **same** command with `--resume` (keep the same RPC and script); Foundry replays pending txs from the local broadcast journal.
4. **Try another RPC** (Alchemy, QuickNode, or a dedicated Amoy URL) if Infura keeps dropping txs.
5. **Confirm on-chain** before copying addresses into `.env`: if the process crashed mid-broadcast, the addresses printed during simulation may not all exist on-chain — check Polygonscan for the deployer account’s recent contracts.

Example resilient broadcast:

```shell
source .env
forge script script/DeployAmoy.s.sol:DeployAmoy \
  --rpc-url $AMOY_RPC_URL \
  --broadcast \
  --verify \
  --slow \
  --gas-estimate-multiplier 130
```

If you see `EIP-3855 is not supported` for chain 80002, that comes from the RPC’s capability reporting; Polygon Amoy supports modern opcodes. A different RPC URL often clears the warning.

**If you see `could not instantiate forked environment` / `dns error` / `Could not resolve host`:** The RPC hostname in `AMOY_RPC_URL` did not resolve or was unreachable (offline Wi‑Fi, VPN/DNS issues, corporate firewall, or a typo in the URL). Confirm with `curl -I "$AMOY_RPC_URL"` (or open the URL in a browser if it is a dashboard URL only). Try another resolver (e.g. system settings → DNS), disconnect VPN, or switch `AMOY_RPC_URL` to another Amoy HTTPS RPC (Alchemy, QuickNode, or [Polygon public endpoints](https://polygon.technology/blog/introducing-the-polygon-zkevm-and-polygon-pos-amoy-testnet)). Ensure the value in `.env` has no surrounding quotes or line breaks.

NOTE : If above command still not works, remove --verify and try again. 

Copy from the console output into `.env`:

- `GOVERNANCE_CONFIG`
- `WHITELIST_REGISTRY`
- `GOLD_NFT`
- `ESCROW_VAULT` (not read by ConfigureRoles; keep for your records)
- `TIMELOCK_CONTROLLER`
- `TRADE_MANAGER`
- `ERC2771_FORWARDER`

`DeployAmoy` always: deploys implementations + proxies, then the **deployer** calls **`setInitialAdmin(INITIAL_ADMIN)`** on every core proxy.

If **`INITIAL_ADMIN` equals the deployer**, the same broadcast continues with **`setRoutingAddresses`**, **`setTradeManager`** (escrow + timelock), and **`TRADE_MANAGER_ROLE`** on `GoldNFT`.

If **`INITIAL_ADMIN` differs from the deployer**, the deploy script **stops before routing** and logs a reminder. Run **`script/WireProxiesAdmin.s.sol`** with **`PRIVATE_KEY` set to the admin key** (and env `TRADE_MANAGER`, `ESCROW_VAULT`, `TIMELOCK_CONTROLLER`, `GOLD_NFT`) to finish wiring.

### 4) Run automated tests (local)

Tests do **not** need Amoy; they deploy fresh proxies on the in-memory EVM:

```shell
forge test -vv
```

`StoexPRD.t.sol` covers buy/sell/redeem/mint/burn, escrow unlock paths, timelocks, co-signatures, governance, whitelist, and soulbound behavior.

### 5) Configure operational roles (`ConfigureRoles`)

**Required** in `.env` (same proxy addresses you saved after deploy — `ConfigureRoles` reads them with `vm.envAddress`, so each line must exist and use `0x…`):

- `TRADE_MANAGER`
- `GOVERNANCE_CONFIG`
- `WHITELIST_REGISTRY`
- `GOLD_NFT`
- `TIMELOCK_CONTROLLER`

Use **`PRIVATE_KEY` = admin** account (holds `DEFAULT_ADMIN_ROLE` on the proxies after handoff). For a cold admin, export that key only for this script in a secure environment.

**Optional** role-holder wallets (omit or `0x0000…` to skip that role):

- `ROLE_AP`, `ROLE_VP`, `ROLE_AT`, `ROLE_PAP`, `ROLE_AUDITOR`
- `ERC2771_FORWARDER` — only if you need to rotate the trusted forwarder after deploy

Then from the project root (so Foundry loads `./.env`):

```shell
source .env
forge script script/ConfigureRoles.s.sol:ConfigureRoles --rpc-url $AMOY_RPC_URL --broadcast # Run this first time
forge script script/ConfigureRoles.s.sol:ConfigureRoles --rpc-url $AMOY_RPC_URL --broadcast --resume --slow # If transaction fails, add resume and slow to run it from broadcasted txs and sending transactions slowly
```

If you still see `environment variable "TRADE_MANAGER" not found`, the names in `.env` must match exactly (e.g. not `TradeManager=`). You can also `export` those variables in the shell before `forge script`.

This grants:

- On **TradeManager**: AP, VP, AT, PAP, Auditor (as set).
- On **GoldNFT**: AP (for `mintCertificate`).
- On **TimelockController**: AP, AT (for timelock admin/override).
- On **GovernanceConfig** and **WhitelistRegistry**: AT (policy + trustee co-approval).

Quick verification with `cast`:

```shell
# Role IDs (same values used in StoexRoles)
AP_ROLE=$(cast keccak "AP_ROLE")
VP_ROLE=$(cast keccak "VP_ROLE")
AT_ROLE=$(cast keccak "AT_ROLE")
PAP_ROLE=$(cast keccak "PAP_ROLE")
AUDITOR_ROLE=$(cast keccak "AUDITOR_ROLE")

# TradeManager role checks
cast call $TRADE_MANAGER "hasRole(bytes32,address)(bool)" $AP_ROLE $ROLE_AP --rpc-url $AMOY_RPC_URL
cast call $TRADE_MANAGER "hasRole(bytes32,address)(bool)" $VP_ROLE $ROLE_VP --rpc-url $AMOY_RPC_URL
cast call $TRADE_MANAGER "hasRole(bytes32,address)(bool)" $AT_ROLE $ROLE_AT --rpc-url $AMOY_RPC_URL
cast call $TRADE_MANAGER "hasRole(bytes32,address)(bool)" $PAP_ROLE $ROLE_PAP --rpc-url $AMOY_RPC_URL
cast call $TRADE_MANAGER "hasRole(bytes32,address)(bool)" $AUDITOR_ROLE $ROLE_AUDITOR --rpc-url $AMOY_RPC_URL

# Registry / Governance / Timelock / Gold role checks
cast call $WHITELIST_REGISTRY "hasRole(bytes32,address)(bool)" $AT_ROLE $ROLE_AT --rpc-url $AMOY_RPC_URL
cast call $GOVERNANCE_CONFIG "hasRole(bytes32,address)(bool)" $AT_ROLE $ROLE_AT --rpc-url $AMOY_RPC_URL
cast call $TIMELOCK_CONTROLLER "hasRole(bytes32,address)(bool)" $AP_ROLE $ROLE_AP --rpc-url $AMOY_RPC_URL
cast call $TIMELOCK_CONTROLLER "hasRole(bytes32,address)(bool)" $AT_ROLE $ROLE_AT --rpc-url $AMOY_RPC_URL
cast call $GOLD_NFT "hasRole(bytes32,address)(bool)" $AP_ROLE $ROLE_AP --rpc-url $AMOY_RPC_URL
```

### 6) Onboard investors (`OnboardInvestors`)

Set investor slots in `.env`:

- `INVESTOR_1` … `INVESTOR_20` (wallets to onboard)
- optional `INVESTOR_1_KYC_REF` … `INVESTOR_20_KYC_REF` (defaults to `KYC-<n>`)

Then run:

```shell
source .env
forge script script/OnboardInvestors.s.sol:OnboardInvestors --rpc-url $AMOY_RPC_URL --broadcast # First time run
source .env
forge script script/OnboardInvestors.s.sol:OnboardInvestors \
  --rpc-url "$AMOY_RPC_URL" \
  --broadcast \
#   --resume \
  --slow \
  --gas-estimate-multiplier 130 \
  --priority-gas-price 35gwei
  # With slow resumed transactions for further runs
```

What this script does for each configured investor wallet:

1. `WhitelistRegistry.registerUser(userId, wallet, kycRef)`
2. `WhitelistRegistry.verifyKYC(wallet)` — **skipped** if `SKIP_KYC_VERIFY=true` (users stay **Pending** and may **buy only** within `nonKycMaxHoldingCap`; run `verifyKYC` later for full access)
3. Grants **`USER_ROLE`** on both `WhitelistRegistry` and `TradeManager`

`userId` is deterministic in this script: `keccak256("INVESTOR_<n>|<wallet>")`.

`USER_ROLE` on `TradeManager` is required for `createBuyRequest` / `createSellRequest` / `createRedeemRequest` (sell/redeem still require **verified** `isEligible`).  
`USER_ROLE` on `WhitelistRegistry` is required for `requestWalletChange` (**verified** users only for meaningful migration flows).

**Restricted buy onboarding example:**

```shell
SKIP_KYC_VERIFY=true forge script script/OnboardInvestors.s.sol:OnboardInvestors --rpc-url $AMOY_RPC_URL --broadcast
```

Quick verification with `cast` (example for `INVESTOR_1`):

```shell
USER_ROLE=$(cast keccak "USER_ROLE")

# Full eligibility (verified KYC)
cast call $WHITELIST_REGISTRY "isEligible(address)(bool)" $INVESTOR_1 --rpc-url $AMOY_RPC_URL
# Pending-KYC buy path (buy only, restricted cap)
cast call $WHITELIST_REGISTRY "isEligibleForRestrictedBuy(address)(bool)" $INVESTOR_1 --rpc-url $AMOY_RPC_URL
# Policy flags
cast call $GOVERNANCE_CONFIG "nonKycMaxHoldingCap()(uint256)" --rpc-url $AMOY_RPC_URL
cast call $GOVERNANCE_CONFIG "vpRequiredForApprovals()(bool)" --rpc-url $AMOY_RPC_URL

# USER_ROLE on both contracts
cast call $WHITELIST_REGISTRY "hasRole(bytes32,address)(bool)" $USER_ROLE $INVESTOR_1 --rpc-url $AMOY_RPC_URL
cast call $TRADE_MANAGER "hasRole(bytes32,address)(bool)" $USER_ROLE $INVESTOR_1 --rpc-url $AMOY_RPC_URL

# Optional: inspect profile snapshot (userId, wallet, KYC/wallet/user status, risk, kycRef, timestamp)
cast call $WHITELIST_REGISTRY "getProfile(address)((bytes32,address,uint8,uint8,uint8,uint8,string,uint256))" $INVESTOR_1 --rpc-url $AMOY_RPC_URL
```

### 7) Run operations (PRD flows)

All flows go through **TradeManager** unless noted. The scripts below execute the exact PRD approval sequence on-chain.
For **strict EIP-2771 gasless** testing, use Step 8 `relayer/src/gasless-runner.js` (meta create/propose via forwarder). These Step 7 scripts remain deterministic direct role-by-role runners.

| Flow | Who starts | Approval order (default) | Execution |
|------|------------|--------------------------|-----------|
| **Buy** | Investor (`createBuyRequest`) | AP → AT | `executeRequest` (admin) or `executeWithCoSignatures` |
| **Sell** | Investor (`createSellRequest`, escrow locks) | AP → AT | Admin execute |
| **Redeem** | Investor (`createRedeemRequest`) | AP → VP → PAP → AT (VP step omitted if `vpRequiredForApprovals` is false) | Admin execute |
| **Mint** | AP (`proposeMint`) | VP → AT (VP omitted if disabled) | Admin execute |
| **Burn** | AP (`proposeBurn`) | VP → AT (VP omitted if disabled) | Admin execute (debits `vaultBookkeeping`) |

**Admin executor** holds `DEFAULT_ADMIN_ROLE` on `TradeManager` and calls `executeRequest(requestId)` after status reaches fully approved (`ATApproved` in storage).

**VP optional**: On `GovernanceConfig`, **`vpRequiredForApprovals`** (default `true`) controls whether `VP_ROLE` appears in the **effective** policy returned by **`getApprovalPolicy`** for **Redeem**, **Mint**, and **Burn**. Toggle with **`setVpRequiredForApprovals`** (admin) or:

```shell
VP_REQUIRED=false forge script script/GovernanceAdminFlags.s.sol:GovernanceAdminFlags --rpc-url $AMOY_RPC_URL --broadcast
```

Buy/Sell default policies are unchanged (no VP step). Co-signatures and `approveRequest` both use the filtered policy.

**EIP-712 co-sign**: integrators hash with `TradeManager.hashCoSignBatch(requestId, nonce, deadline)` using domain `StoexGoldTrade` / version `1`, then call `executeWithCoSignatures` (see tests in `StoexPRD.t.sol`).

**Direct certificate mint**: AP calls `GoldNFT.mintCertificate(user)` when you want a certificate before any trade execution.

#### Step 7.0 - Shared env for operation scripts

Add these in `.env` for script-driven flow execution:

- Required: `TRADE_MANAGER`, `AMOY_RPC_URL`
- Required for user-initiated flows: `USER_PRIVATE_KEY` (must map to an onboarded wallet with `USER_ROLE`)
- Optional (fallback to `PRIVATE_KEY`): `ADMIN_PRIVATE_KEY`, `AP_PRIVATE_KEY`, `VP_PRIVATE_KEY`, `AT_PRIVATE_KEY`, `PAP_PRIVATE_KEY`

You can keep one key for all roles in testing if the same wallet holds those roles.

#### Step 7.1 - Buy flow script (PRD order: USER -> AP -> AT -> EXECUTE)

Optional inputs:

- `BUY_GRAMS` (default `1000`)
- `BUY_PAYMENT_REF` (default `"BUY-REF-001"` as bytes32)

Run:

```shell
source .env
forge script script/BuyFlow.s.sol:BuyFlow --rpc-url $AMOY_RPC_URL --broadcast --slow
```

#### Step 7.2 - Sell flow script (PRD order: USER -> AP -> AT -> EXECUTE)

Precondition: investor already has enough grams in `GoldNFT.userHolding`.

Optional inputs:

- `SELL_GRAMS` (default `500`)
- `SELL_PAYOUT_REF` (default `"SELL-REF-001"` as bytes32)

Run:

```shell
source .env
forge script script/SellFlow.s.sol:SellFlow --rpc-url $AMOY_RPC_URL --broadcast --slow
```

#### Step 7.3 - Redeem flow script (PRD order: USER -> AP -> VP -> PAP -> AT -> EXECUTE)

Precondition: investor already has enough grams and is not timelocked for redeem.

Optional inputs:

- `REDEEM_GRAMS` (default `1000`)
- `REDEEM_DELIVERY_REF` (default `"REDEEM-REF-001"` as bytes32)

Run:

```shell
source .env
forge script script/RedeemFlow.s.sol:RedeemFlow --rpc-url $AMOY_RPC_URL --broadcast --slow
```

#### Step 7.4 - Mint flow script (PRD order: AP -> VP -> AT -> EXECUTE)

Required inputs:

- `MINT_CREDIT_TO` (onboarded/eligible investor wallet to receive grams)

Optional inputs:

- `MINT_GRAMS` (default `1000`)
- `MINT_VAULT_RECEIPT_ID` (default `"VAULT-RCPT-001"` as bytes32)
- `MINT_BATCH_ID` (default `"BATCH-001"` as bytes32)
- `MINT_PURITY` (default `999`)
- `MINT_DEPOSIT_TS` (default `block.timestamp`)
- `MINT_AP_ID`, `MINT_VP_ID` (defaults to broadcaster addresses for AP/VP keys)
- `MINT_LOCK_UNTIL_TS` (default `0`)

Run:

```shell
source .env
forge script script/MintFlow.s.sol:MintFlow --rpc-url $AMOY_RPC_URL --broadcast --slow
```

#### Step 7.5 - Burn flow script (PRD order: AP -> VP -> AT -> EXECUTE)

Precondition: `vaultBookkeeping` must be eligible and have enough grams, because burn debits that holder.

Optional inputs:

- `BURN_GRAMS` (default `500`)
- `BURN_REF_ID` (default `"BURN-REF-001"` as bytes32)
- `BURN_REASON` (default `"Ops burn"`)

Run:

```shell
source .env
forge script script/BurnFlow.s.sol:BurnFlow --rpc-url $AMOY_RPC_URL --broadcast --slow
```

#### Step 7.6 - Verify operation result quickly

Read latest request ID and status:

```shell
cast call $TRADE_MANAGER "nextRequestId()(uint256)" --rpc-url $AMOY_RPC_URL
cast call $TRADE_MANAGER "getRequestStatus(uint256)(uint8)" <REQUEST_ID> --rpc-url $AMOY_RPC_URL
```

Expected status after successful script run: `5` (`Executed`).

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
- `TRADE_MANAGER`
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

4. Run gasless flow runner (meta-tx create/propose + on-chain approvals/execution):

```shell
# Sequential (default)
npm run run:gasless

# Parallel mode for independent test runs
GASLESS_PARALLEL=true GASLESS_FLOWS=buy,sell,redeem,mint,burn npm run run:gasless
```

`run:gasless` uses `/typed-data` + wallet signatures + `/relay` for gasless request creation/proposal, then performs the PRD approval chain and `executeRequest` with configured role wallets.
Use `GASLESS_FLOWS` to select a subset (example: `GASLESS_FLOWS=buy,sell`).

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
