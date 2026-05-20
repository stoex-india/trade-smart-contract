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
| `script/BuyFlow.s.sol` | **`createBuyRequest` only** — buy settles in one tx (no admin execute) |
| `script/SellFlow.s.sol` | Sell request lifecycle (USER -> AP -> AT -> ADMIN execute) |
| `script/RedeemFlow.s.sol` | Redeem lifecycle (USER -> AP -> VP -> PAP -> AT -> ADMIN execute) |
| `script/MintFlow.s.sol` | Mint lifecycle (AP -> VP -> AT -> ADMIN execute) |
| `script/BurnFlow.s.sol` | Burn lifecycle (AP -> VP -> AT -> ADMIN execute) |
| `test/helpers/StoexFixture.sol` | Shared deployment for tests |
| `test/StoexPRD.t.sol` | PRD-mapped integration tests |
| `docs/` | Integration and API documentation for contracts + SDK-driven gasless flows |

---

## Step-by-step: environment → deploy → test → roles → operations

### Deployer vs operations admin (RBAC)

- **Deployer** (`deployer` on-chain): the wallet passed into each contract’s `initialize`. It has **no** `DEFAULT_ADMIN_ROLE` after deployment. It may call **`setInitialAdmin(admin)` exactly once** per proxy to grant the operations admin.
- **Admin** (`DEFAULT_ADMIN_ROLE`): pauses, upgrades (UUPS), `TradeManager.executeRequest` (**Sell / Redeem / Mint / Burn** only — **not Buy**), `GovernanceConfig.setMinimumBuyGoldValueInMg`, forwarder rotation, `GovernanceConfig.setVpRequiredForApprovals`, registry KYC, etc. Admins rotate with **`transferAdmin(newAdmin)`** (callable only by the current admin, on each contract where rotation is needed).
- **Asset Trustee (`AT_ROLE`)** still updates economic policy on `GovernanceConfig` (caps, approval *matrices*, `nonKycMaxBuyFiatAmount`, etc.). **VP on/off** is admin-only and implemented by filtering `VP_ROLE` out of the *effective* approval path for Redeem / Mint / Burn when disabled (see `getApprovalPolicy`).

### KYC tiers (buy vs full access)

- **`registerUser`** creates a **Pending** KYC profile. **`isEligibleForNonKycUser`** is true for Pending users (whitelisted wallet, active, within risk rules). They may **`createBuyRequest` only**, subject to **`GovernanceConfig.nonKycMaxBuyFiatAmount`**: cumulative executed **`fiat_value`** (INR minor units, e.g. paise) must stay within cap (Asset Trustee adjusts via **`setNonKycMaxBuyFiatAmount`**).
- **`verifyKYC`** (admin) moves a user to **Verified** → **`isEligible`** is true → sell, redeem, full daily buy cap (`dailyBuyCap`), mint/burn bookkeeping paths, nominee transfer, etc., as before.
- **`rejectKYC`** users are not eligible for the non-KYC buy path.

### Gold supply accounting (`GoldNFT`)

All gold integers are **micrograms (µg)** unless noted otherwise. **`1 gram = 1_000_000 µg`**. Off-chain UI may display grams using `GovernanceConfig.goldPrecision()` (default **6**).

- **`totalGoldSupply`**: µg tracked on-chain; increases only when **`increaseSupply`** runs (mint path), decreases on redeem/burn (**`decreaseSupply`** with `Redeem` / `Burn`).
- **`totalAssetProviderBalance`**: µg in the **Asset Provider buy pool**. Buys call **`transferFromAPToUser`** (same tx as **`createBuyRequest`**); users do not mint new supply on buy. Sells return µg to the pool (`Sell`). **`seedPoolInventory`** (admin) increases both **`totalGoldSupply`** and **`totalAssetProviderBalance`** when onboarding vaulted inventory into the pool.
- **`circulatingSupply()`** = **`totalGoldSupply - totalAssetProviderBalance`**.

**Buy** validates pool depth, eligibility, `minimumBuyGoldValueInUg`, per-tx / daily caps, and non-KYC fiat cap; then **credits the user in the same transaction** (no `executeRequest`).

**Redeploy note:** this repo does not ship on-chain data migration. Deploy fresh proxies and re-seed pool inventory after unit changes.

### 1) Install Foundry and clone

Install Foundry, then work in this package:

```shell
cd trade-smart-contract
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

For **`forge script ... --verify`** (Polygon Amoy source verification), set **`POLYGONSCAN_API_KEY`** in `.env` (same name as in `foundry.toml` under `[etherscan]`). Get a key from [Polygonscan API](https://docs.polygonscan.com/getting-started/viewing-api-usage-statistics). If you deploy without it, contracts still deploy; only verification fails—omit `--verify` or verify later with `forge verify-contract`.

### 3) Deploy to Amoy

Dry run (no transaction broadcast):

```shell
source .env
forge script script/DeployAmoy.s.sol:DeployAmoy --rpc-url $AMOY_RPC_URL -vvv
```

Broadcast (deploy only — no explorer verification):

```shell
source .env
forge script script/DeployAmoy.s.sol:DeployAmoy \
  --rpc-url $AMOY_RPC_URL \
  --broadcast \
  --slow \
  --verify \
  --gas-estimate-multiplier 130 \
  --priority-gas-price 35gwei
```

Optional: append **`--verify`** only if **`POLYGONSCAN_API_KEY`** is set in `.env` (see §2).

**Amoy gas tip:** If the RPC returns `transaction gas price below minimum` / `gas tip cap … minimum needed 25000000000`, the chain requires a **priority fee of at least ~25 gwei**. Set **`--priority-gas-price 35gwei`** (or higher if the network is busy). Without this, Forge can submit txs with a near‑zero tip and the node will reject them before anything is mined.

**If broadcast flakes:** Public RPCs often drop transactions from the mempool when the fee is tight or the endpoint is busy. You may see `dropped from the mempool` and, on Foundry 1.5.x, a crash (`attempt to divide by zero` in `broadcast.rs`) — that is a [known Foundry bug](https://github.com/foundry-rs/foundry/issues/13507) when receipts are missing, not a fault in this repo. Mitigations:

1. **Send slowly** (one tx at a time, waits for receipts): add `--slow`.
2. **Raise fees** so txs are not evicted: `--gas-estimate-multiplier 130` and **`--priority-gas-price 35gwei`** (raise if needed).
3. **Resume** after a partial run: rerun the **same** command with `--resume` (keep the same RPC and script); Foundry replays pending txs from the local broadcast journal.
4. **Try another RPC** (Alchemy, QuickNode, or a dedicated Amoy URL) if Infura keeps dropping txs.
5. **Confirm on-chain** before copying addresses into `.env`: if the process crashed mid-broadcast, the addresses printed during simulation may not all exist on-chain — check Polygonscan for the deployer account’s recent contracts.

If you see `EIP-3855 is not supported` for chain 80002, that comes from the RPC’s capability reporting; Polygon Amoy supports modern opcodes. A different RPC URL often clears the warning.

**If you see `could not instantiate forked environment` / `dns error` / `Could not resolve host`:** The RPC hostname in `AMOY_RPC_URL` did not resolve or was unreachable (offline Wi‑Fi, VPN/DNS issues, corporate firewall, or a typo in the URL). Confirm with `curl -I "$AMOY_RPC_URL"` (or open the URL in a browser if it is a dashboard URL only). Try another resolver (e.g. system settings → DNS), disconnect VPN, or switch `AMOY_RPC_URL` to another Amoy HTTPS RPC (Alchemy, QuickNode, or [Polygon public endpoints](https://polygon.technology/blog/introducing-the-polygon-zkevm-and-polygon-pos-amoy-testnet)). Ensure the value in `.env` has no surrounding quotes or line breaks.

Copy from the console output into `.env`:

- `GOVERNANCE_CONFIG`
- `WHITELIST_REGISTRY`
- `GOLD_NFT`
- `ESCROW_VAULT` (not read by ConfigureRoles; keep for your records)
- `TIMELOCK_CONTROLLER`
- `TRADE_MANAGER`
- `ERC2771_FORWARDER` (Tresori SDK Relayer/Facilitator forwarder contract address, we wont deploy our own forwarder)

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
- `RELAYER_SMART_CONTRACT` — Tresori gasless forwarder/relayer contract used as trusted forwarder

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
- optional `INVESTOR_1_VERIFY_KYC` … `INVESTOR_20_VERIFY_KYC` (`true|false`, per-investor override)
- optional global `SKIP_KYC_VERIFY` fallback (`true|false`)

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
2. `WhitelistRegistry.verifyKYC(wallet)` — controlled per investor by `INVESTOR_<n>_VERIFY_KYC` (if set). If unset, falls back to global `SKIP_KYC_VERIFY` (users skipped remain **Pending** and may **buy only** within `nonKycMaxBuyFiatAmount`)
3. Grants **`USER_ROLE`** on both `WhitelistRegistry` and `TradeManager`

`userId` is deterministic in this script: `keccak256("INVESTOR_<n>|<wallet>")`.

`USER_ROLE` on `TradeManager` is required for `createBuyRequest` / `createSellRequest` / `createRedeemRequest` (sell/redeem still require **verified** `isEligible`).  
`USER_ROLE` on `WhitelistRegistry` is required for `requestWalletChange` (**verified** users only for meaningful migration flows).

**Non-KYC (pending) buy onboarding example:**

```shell
SKIP_KYC_VERIFY=true forge script script/OnboardInvestors.s.sol:OnboardInvestors --rpc-url $AMOY_RPC_URL --broadcast

# Example mixed onboarding: investor 1 pending, investor 2 verified
# INVESTOR_1=0x...
# INVESTOR_1_VERIFY_KYC=false
# INVESTOR_2=0x...
# INVESTOR_2_VERIFY_KYC=true
```

Quick verification with `cast` (example for `INVESTOR_1`):

```shell
USER_ROLE=$(cast keccak "USER_ROLE")

# Full eligibility (verified KYC)
cast call $WHITELIST_REGISTRY "isEligible(address)(bool)" $INVESTOR_1 --rpc-url $AMOY_RPC_URL
# Pending-KYC buy path (buy only; cumulative fiat cap)
cast call $WHITELIST_REGISTRY "isEligibleForNonKycUser(address)(bool)" $INVESTOR_1 --rpc-url $AMOY_RPC_URL
# Policy flags
cast call $GOVERNANCE_CONFIG "nonKycMaxBuyFiatAmount()(uint256)" --rpc-url $AMOY_RPC_URL
cast call $GOVERNANCE_CONFIG "vpRequiredForApprovals()(bool)" --rpc-url $AMOY_RPC_URL
cast call $GOVERNANCE_CONFIG "minimumBuyGoldValueInUg()(uint256)" --rpc-url $AMOY_RPC_URL

# USER_ROLE on both contracts
cast call $WHITELIST_REGISTRY "hasRole(bytes32,address)(bool)" $USER_ROLE $INVESTOR_1 --rpc-url $AMOY_RPC_URL
cast call $TRADE_MANAGER "hasRole(bytes32,address)(bool)" $USER_ROLE $INVESTOR_1 --rpc-url $AMOY_RPC_URL

# Optional: inspect profile snapshot (userId, wallet, KYC/wallet/user status, risk, kycRef, timestamp)
cast call $WHITELIST_REGISTRY "getProfile(address)((bytes32,address,uint8,uint8,uint8,uint8,string,uint256))" $INVESTOR_1 --rpc-url $AMOY_RPC_URL
```

### 7) Run operations (PRD flows)

All flows go through **TradeManager** unless noted. The scripts below execute the exact PRD approval sequence on-chain.
Step 7 scripts remain deterministic direct role-by-role runners. For user gasless flows in production, use Tresori SDK `writeGaslessMpcSmartContractTransaction(...)` as described in Step 8.

| Flow | Who starts | Approval order (default) | Execution |
|------|------------|--------------------------|-----------|
| **Buy** | Investor (`createBuyRequest(weightUg, fiat_value, payment_ref, txDetailsHash)`) | *none* | *Immediate* — request stored as **Executed**; `GoldNFT.transferFromAPToUser` in same call |
| **Sell** | Investor (`createSellRequest`, escrow locks) | AP → AT | Admin execute |
| **Redeem** | Investor (`createRedeemRequest`) | AP → VP → PAP → AT (VP step omitted if `vpRequiredForApprovals` is false) | Admin execute |
| **Mint** | AP (`proposeMint`) | VP → AT (VP omitted if disabled) | Admin execute |
| **Burn** | AP (`proposeBurn`) | VP → AT (VP omitted if disabled) | Admin execute (debits `vaultBookkeeping`) |

**Admin executor** holds `DEFAULT_ADMIN_ROLE` on `TradeManager` and calls `executeRequest(requestId)` for **non-Buy** flows after status reaches fully approved (`ATApproved`). **`executeRequest` reverts** if `requestType == Buy` (buys are never pending).

**VP optional**: On `GovernanceConfig`, **`vpRequiredForApprovals`** (default `true`) controls whether `VP_ROLE` appears in the **effective** policy returned by **`getApprovalPolicy`** for **Redeem**, **Mint**, and **Burn**. Toggle with **`setVpRequiredForApprovals`** (admin) or:

```shell
VP_REQUIRED=false forge script script/GovernanceAdminFlags.s.sol:GovernanceAdminFlags --rpc-url $AMOY_RPC_URL --broadcast
```

**Buy** does not use `getApprovalPolicy` (no AP/AT, no admin execute). **Sell** default policy is unchanged (AP → AT, no VP step). Co-signatures and `approveRequest` apply to **non-Buy** request types with a non-empty policy.

**`GovernanceConfig`**: `minimumBuyGoldValueInUg` (admin, **`setMinimumBuyGoldValueInUg`**) enforces a floor on buy size; set to **0** to disable the floor. **Amount caps** (`dailyBuyCap`, `maxAmountPerTx`, `minRedeemAmountUg`, etc.) are expressed in **µg** (`goldPrecision` default is **6** for gram display).

**EIP-712 co-sign**: integrators hash with `TradeManager.hashCoSignBatch(requestId, nonce, deadline)` using domain `StoexGoldTrade` / version `1`, then call `executeWithCoSignatures` (see tests in `StoexPRD.t.sol`).

**Direct certificate mint**: AP calls `GoldNFT.mintCertificate(user)` when you want a certificate before any trade execution.

#### Step 7.0 - Shared env for operation scripts

Add these in `.env` for script-driven flow execution:

- Required: `TRADE_MANAGER`, `AMOY_RPC_URL`
- Required for user-initiated flows: `USER_PRIVATE_KEY` (must map to an onboarded wallet with `USER_ROLE`)
- Optional (fallback to `PRIVATE_KEY`): `ADMIN_PRIVATE_KEY`, `AP_PRIVATE_KEY`, `VP_PRIVATE_KEY`, `AT_PRIVATE_KEY`, `PAP_PRIVATE_KEY`

You can keep one key for all roles in testing if the same wallet holds those roles.

#### Step 7.1 - Buy flow script (single user transaction)

Optional inputs:

- `BUY_WEIGHT_UG` — gold amount in **micrograms** (default `1000000` = 1 g)
- `BUY_FIAT_VALUE` (default `1`) — INR minor units for `fiat_value` (must be non-zero on-chain)
- `BUY_PAYMENT_REF` (default `"BUY-REF-001"` as bytes32)
- `BUY_TX_DETAILS_HASH` (optional `bytes32`) — bank/UPI audit hash

Precondition: **`GoldNFT.totalAssetProviderBalance`** must cover the buy (fund pool via inventory ops / **`seedPoolInventory`** / sells returning to pool).

Run:

```shell
source .env
forge script script/BuyFlow.s.sol:BuyFlow --rpc-url $AMOY_RPC_URL --broadcast --slow
```

#### Step 7.2 - Sell flow script (PRD order: USER -> AP -> AT -> EXECUTE)

Precondition: investor already has enough µg in `GoldNFT.userHolding`.

Optional inputs:

- `SELL_AMOUNT_UG` (default `500000` = 0.5 g)
- `SELL_PAYOUT_REF` (default `"SELL-REF-001"` as bytes32)

Run:

```shell
source .env
forge script script/SellFlow.s.sol:SellFlow --rpc-url $AMOY_RPC_URL --broadcast --slow
```

#### Step 7.3 - Redeem flow script (PRD order: USER -> AP -> VP -> PAP -> AT -> EXECUTE)

Precondition: investor already has enough µg and is not timelocked for redeem.

Optional inputs:

- `REDEEM_AMOUNT_UG` (default `1000000` = 1 g)
- `REDEEM_DELIVERY_REF` (default `"REDEEM-REF-001"` as bytes32)

Run:

```shell
source .env
forge script script/RedeemFlow.s.sol:RedeemFlow --rpc-url $AMOY_RPC_URL --broadcast --slow
```

#### Step 7.4 - Mint flow script (PRD order: AP -> VP -> AT -> EXECUTE)

Required inputs:

- `MINT_CREDIT_TO` (onboarded/eligible investor wallet to receive gold)

Optional inputs:

- `MINT_AMOUNT_UG` (default `1000000` = 1 g)
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

Precondition: `vaultBookkeeping` must be eligible and have enough µg, because burn debits that holder.

Optional inputs:

- `BURN_AMOUNT_UG` (default `500000` = 0.5 g)
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

### 8) Gasless (Tresori SDK EIP-2771)

Contracts with trusted forwarder support in this repo:

- `TradeManager` (buy/sell/redeem/mint/burn and approvals)
- `WhitelistRegistry` (user/admin registry functions)
- `GoldNFT` (AP mint/admin operations)

Use Tresori SDK `writeGaslessMpcSmartContractTransaction(...)` for user gasless writes.  

#### Step 8.1 - Set trusted forwarder to Tresori gasless contract

Set in `.env`:

- `RELAYER_SMART_CONTRACT` = Tresori gasless forwarder/relayer contract for the target chain

Run:

```shell
source .env
forge script script/SetTrustedForwarder.s.sol:SetTrustedForwarder --rpc-url $AMOY_RPC_URL --broadcast
```

This updates:

- `TradeManager.setTrustedForwarder(...)`
- `WhitelistRegistry.setTrustedForwarder(...)`
- `GoldNFT.setTrustedForwarder(...)`

Verify trusted forwarder addresses:

```shell
source .env
cast call $TRADE_MANAGER "trustedForwarder()(address)" --rpc-url $AMOY_RPC_URL
cast call $WHITELIST_REGISTRY "trustedForwarder()(address)" --rpc-url $AMOY_RPC_URL
cast call $GOLD_NFT "trustedForwarder()(address)" --rpc-url $AMOY_RPC_URL

# Optional: compare against expected
echo "Expected RELAYER_SMART_CONTRACT=$RELAYER_SMART_CONTRACT"
```

#### Step 8.2 - Frontend/client gasless call shape

Use Tresori SDK:

```ts
await TreSori().writeGaslessMpcSmartContractTransaction({
  contractAddress: TRADE_MANAGER,
  functionName: "createBuyRequest",
  params: [weightUg, fiatValue, paymentRefBytes32, txDetailsHashBytes32],
  abi: [
    "function createBuyRequest(uint256 weightUg,uint256 fiat_value,bytes32 payment_ref,bytes32 txDetailsHash)"
  ],
  fromAddress: userMpcWallet,
  chain: selectedChain,
  clientShare,
  sessionId,
  rpcUrl: AMOY_RPC_URL
});
```

Use the same function for:

- `createSellRequest(...)`
- `createRedeemRequest(...)`
- `proposeMint(...)`
- `proposeBurn(...)`

#### Step 8.3 - Validation checklist

For each gasless operation:

1. `fromAddress` has required role on-chain (`USER_ROLE` for buy/sell/redeem, `AP_ROLE` for mint/burn).
2. `RequestCreated.initiator` equals MPC user/operator wallet.
3. Buy settles as `Executed` in same tx.
4. Non-buy requests follow normal approval/execution path.

### 9) Useful `cast` examples

Read eligibility:

```shell
cast call $WHITELIST_REGISTRY "isEligible(address)(bool)" $INVESTOR_WALLET --rpc-url $AMOY_RPC_URL
```

Read holding (balance is **micrograms**; divide by `1_000_000` for grams):

```shell
cast call $GOLD_NFT "userHolding(address)(uint256)" $INVESTOR_WALLET --rpc-url $AMOY_RPC_URL
```

Supply snapshot:

```shell
cast call $GOLD_NFT "totalGoldSupply()(uint256)" --rpc-url $AMOY_RPC_URL
cast call $GOLD_NFT "totalAssetProviderBalance()(uint256)" --rpc-url $AMOY_RPC_URL
cast call $GOLD_NFT "circulatingSupply()(uint256)" --rpc-url $AMOY_RPC_URL
```

---

## NatSpec

Contracts under `src/` include file- and contract-level documentation describing roles, invariants, and how each module maps to the PRD.

## License

MIT (see SPDX headers in source files).
