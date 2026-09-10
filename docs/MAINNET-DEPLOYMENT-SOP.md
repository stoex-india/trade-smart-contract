# SOP — Polygon mainnet deployment

**System:** STOEX trade smart contracts (UUPS proxies)  
**Target:** Polygon PoS mainnet, chain ID **`137`**  
**Script:** `script/DeployAmoy.s.sol` (chain-agnostic despite the name — it deploys to whatever `--rpc-url` you pass)  
**Inventory:** [CONTRACT-INVENTORY.md](CONTRACT-INVENTORY.md)  
**Go-live gate:** [GO-LIVE-CHECKLIST.md](GO-LIVE-CHECKLIST.md)

This SOP is the only approved path to production. Amoy is the rehearsal network; do not copy Amoy proxy addresses onto mainnet.

---

## 1. Roles

| Role | On-chain | This SOP |
|------|----------|----------|
| **Deployer** | `initialize(deployer_)`; one-shot `setInitialAdmin` | Holds `PRIVATE_KEY` for `DeployAmoy` |
| **Admin** | `DEFAULT_ADMIN_ROLE` after handoff | Holds `INITIAL_ADMIN` key for wiring if distinct; later execute / pause / upgrade |
| **Recorder** | — | Pastes addresses into inventory + `.env` (never commits secrets) |

V1 trade path: **admin** and **user** only. `TRADE_MANAGER_ROLE` is granted to the TradeManager **proxy** on `AssetLedger`. AP / VP / AT / PAP are unused for live flows.

---

## 2. Preconditions

1. Go-live checklist sections 1–5 are complete.
2. Foundry (`forge`, `cast`) installed; repo at the **release git tag**.
3. Working directory: `trade-smart-contract/`.
4. Dedicated mainnet RPC (`POLYGON_RPC_URL`). Public `polygon-rpc.com` is not reliable for a multi-tx broadcast.
5. `POLYGONSCAN_API_KEY` in `.env`.
6. Deployer and admin wallets funded with POL.
7. `RELAYER_SMART_CONTRACT` = **Polygon mainnet** Tresori relayer (must be non-zero; deploy script reverts otherwise).

Copy env template if needed:

```shell
cp .env.example .env
```

Minimum `.env` for mainnet:

```shell
POLYGON_RPC_URL=https://polygon-mainnet.g.alchemy.com/v2/<KEY>
POLYGONSCAN_API_KEY=<key>
PRIVATE_KEY=0x<deployer>
INITIAL_ADMIN=0x<ops-admin>          # or same as deployer (not preferred in prod)
RELAYER_SMART_CONTRACT=0x<mainnet-tresori-relayer>

DEFAULT_PROVIDER_LABEL=AP1
DEFAULT_PROVIDER_NAME=MMTC
# ROLE_AP=0x...                      # optional operator metadata
ASSET_PROVIDER_PAYOUT=0x<production-payout>
REDEEM_SINK=0x<production-sink>      # defaults to 0x...dEaD if unset
```

---

## 3. Safety rules

- Never broadcast from a laptop on public Wi‑Fi without a stable RPC.
- Never reuse an Amoy broadcast `--resume` journal against mainnet (different chain).
- Confirm **chain ID** before the first signed tx: `cast chain-id --rpc-url $POLYGON_RPC_URL` must print `137`.
- If broadcast dies mid-way, **do not** start a second fresh deploy. Resume (step 6) or abandon and inventory what already exists.
- Console addresses from a **simulation** are not live until the corresponding receipts exist on Polygonscan.

---

## 4. Build and test (local)

```shell
cd trade-smart-contract
source .env
forge build
forge test -vv
```

Do not proceed if tests fail.

---

## 5. Dry-run against mainnet (no broadcast)

```shell
source .env
cast chain-id --rpc-url $POLYGON_RPC_URL   # expect 137

forge script script/DeployAmoy.s.sol:DeployAmoy \
  --rpc-url $POLYGON_RPC_URL \
  -vvv
```

Expect logs for eight proxies plus trusted forwarder and `INITIAL_ADMIN`. Fix env errors here (zero relayer, missing key, RPC).

---

## 6. Broadcast

Use **legacy gas** if the RPC rejects EIP-1559 the same way Amoy does. Start conservative; raise `gas-price` if the node says the fee is too low.

```shell
source .env
forge script script/DeployAmoy.s.sol:DeployAmoy \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast \
  --slow \
  --legacy \
  --with-gas-price 50gwei \
  --verify \
  --verifier-url https://api.polygonscan.com/api \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --chain 137
```

`--slow` sends one tx at a time and waits for receipts. That is required: this script deploys many contracts in one run.

**If a tx is dropped / Foundry crashes:**

```shell
# Same command + --resume (do not change RPC, script, or wallet)
forge script script/DeployAmoy.s.sol:DeployAmoy \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast --resume --slow \
  --legacy --with-gas-price 50gwei
```

Then verify on Polygonscan that **all** CREATE receipts exist for the deployer before copying addresses.

**If `INITIAL_ADMIN` equals the deployer:** the same broadcast also registers GOLD/SILVER, default provider, routing, and wires TradeManager. Skip step 7.

**If `INITIAL_ADMIN` differs:** the script stops after `setInitialAdmin` and logs that you must run `ConfigureDeployment`. Continue to step 7.

---

## 7. Admin wiring (only if admin ≠ deployer)

Paste proxy addresses from the deploy logs into `.env` (`GOVERNANCE_CONFIG`, `ASSET_REGISTRY`, `ASSET_PROVIDER_REGISTRY`, `WHITELIST_REGISTRY`, `ASSET_LEDGER`, `ESCROW_VAULT`, `TIMELOCK_CONTROLLER`, `TRADE_MANAGER`).

Switch `PRIVATE_KEY` to the **admin** key (or export it only in a secure shell):

```shell
source .env
forge script script/ConfigureDeployment.s.sol:ConfigureDeployment \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast --slow \
  --legacy --with-gas-price 50gwei
```

`ConfigureDeployment` requires `PRIVATE_KEY` to be `INITIAL_ADMIN`. It:

1. Registers GOLD (`AU`) and SILVER (`AG`)
2. Registers default provider, optional operator, asset flags, sell/redeem routing
3. `EscrowVault.setTradeManager` / `TimelockController.setTradeManager`
4. `AssetLedger.grantRole(TRADE_MANAGER_ROLE, TradeManager)`
5. `WhitelistRegistry.setTradeManager`

If assets/providers were already registered and you only need the TradeManager links, `script/WireProxiesAdmin.s.sol` is the narrower alternative.

---

## 8. Trusted forwarder

Deploy already passes `RELAYER_SMART_CONTRACT` into `initialize`. Confirm, and rotate only if Tresori provided a different mainnet address after deploy:

```shell
source .env
cast call $TRADE_MANAGER "trustedForwarder()(address)" --rpc-url $POLYGON_RPC_URL
cast call $WHITELIST_REGISTRY "trustedForwarder()(address)" --rpc-url $POLYGON_RPC_URL
cast call $ASSET_LEDGER "trustedForwarder()(address)" --rpc-url $POLYGON_RPC_URL
```

If any mismatch:

```shell
forge script script/SetTrustedForwarder.s.sol:SetTrustedForwarder \
  --rpc-url $POLYGON_RPC_URL \
  --broadcast --slow --legacy --with-gas-price 50gwei
```

(`PRIVATE_KEY` must be the admin.)

---

## 9. Explorer verification (if `--verify` missed some)

Foundry profile already has Amoy; mainnet uses the Polygonscan API URL in the command above. To verify a single implementation:

```shell
# Example — replace address and contract name
forge verify-contract \
  --chain 137 \
  --verifier-url https://api.polygonscan.com/api \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --watch \
  <IMPLEMENTATION_ADDRESS> \
  src/TradeManager.sol:TradeManager
```

Proxies: verify as OpenZeppelin `ERC1967Proxy` **or** rely on Polygonscan’s proxy match after the implementation is verified, then use **Read as Proxy**.

Implementation slot (EIP-1967):

```shell
IMPL_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
cast storage $TRADE_MANAGER $IMPL_SLOT --rpc-url $POLYGON_RPC_URL
```

`TradeManagerLib` is a linked library — verify it too (`src/libraries/TradeManagerLib.sol:TradeManagerLib`).

---

## 10. Record addresses

1. Fill the **Polygon mainnet** tables in [CONTRACT-INVENTORY.md](CONTRACT-INVENTORY.md) (proxy + implementation + Polygonscan links).
2. Keep a private ops copy of `.env` with mainnet proxies (not in git).
3. Store the Foundry broadcast journal: `broadcast/DeployAmoy.s.sol/137/run-latest.json`.
4. Record git tag, deployer, admin, relayer, payout, sink, and UTC timestamp.

---

## 11. Mandatory on-chain checks

```shell
source .env
RPC=$POLYGON_RPC_URL
ADMIN=$INITIAL_ADMIN
DEFAULT_ADMIN=$(cast keccak "DEFAULT_ADMIN_ROLE")   # 0x00…00
TM_ROLE=$(cast keccak "TRADE_MANAGER_ROLE")
GOLD=$(cast keccak "GOLD")
AP1=$(cast keccak "AP1")

# Version + admin
cast call $TRADE_MANAGER "version()(uint8)" --rpc-url $RPC
cast call $TRADE_MANAGER "hasRole(bytes32,address)(bool)" $DEFAULT_ADMIN $ADMIN --rpc-url $RPC
cast call $ASSET_LEDGER "hasRole(bytes32,address)(bool)" $TM_ROLE $TRADE_MANAGER --rpc-url $RPC

# Catalog + provider
cast call $ASSET_REGISTRY "isAssetActive(bytes32)(bool)" $GOLD --rpc-url $RPC
cast call $ASSET_PROVIDER_REGISTRY "getProvider(bytes32)(bool,string)" $AP1 --rpc-url $RPC
cast call $ASSET_PROVIDER_REGISTRY "getSellPayout(bytes32,bytes32)(address)" $AP1 $GOLD --rpc-url $RPC

# Pause is off
cast call $TRADE_MANAGER "paused()(bool)" --rpc-url $RPC
cast call $ASSET_LEDGER "paused()(bool)" --rpc-url $RPC
```

Then run the smoke trades from the go-live checklist (tiny sizes) from the production app or Foundry flow scripts pointed at `$POLYGON_RPC_URL`.

---

## 12. Frontend / backend cutover

1. Point clients at chain `137` and the eight **proxy** addresses (never implementations).
2. Ship `abi/*.abi.json` from the same git tag.
3. Gasless user calls: Tresori `writeGaslessMpcSmartContractTransaction` on `*For` methods ([FRONTEND_INTEGRATION.md](FRONTEND_INTEGRATION.md)).
4. Admin execute/reject: paid `writeMpcSmartContractTransaction`.
5. Amoy users are **not** migrated. They must register again on mainnet.

---

## 13. Emergency procedures

### Pause (halt new trades / ledger mutations)

Admin on each contract:

```shell
cast send $TRADE_MANAGER "pause()" --rpc-url $POLYGON_RPC_URL --private-key $ADMIN_PRIVATE_KEY --legacy --gas-price 50gwei
cast send $ASSET_LEDGER "pause()" --rpc-url $POLYGON_RPC_URL --private-key $ADMIN_PRIVATE_KEY --legacy --gas-price 50gwei
```

Unpause with `unpause()` when the incident is closed.

Pause does not unlock escrow. In-flight sell/redeem stay `Proposed` until `executeRequest`, `rejectRequest`, user `cancelRequestFor`, or `expireRequest` after TTL.

### Wrong configuration (routing, forwarder, caps)

Admin setters: `setAssetRouting`, `setTrustedForwarder`, `GovernanceConfig` policy setters. Do **not** redeploy proxies to fix config.

### Broken implementation

UUPS `upgradeToAndCall` from admin only, after a new implementation is deployed and a storage-layout review is signed. Out of scope for first go-live.

### Lost admin key

There is **no** recovery path except the current admin calling `transferAdmin`. If the admin key is lost, proxies are not rotatable. This is why admin custody is a go-live blocker.

---

## 14. After-action

- [ ] Inventory status = Live; Polygonscan links clickable.
- [ ] Checklist go/no-go signed.
- [ ] Deployer key removed from engineer laptops / CI.
- [ ] First 24h on-call knows pause + Polygonscan + Tresori status.

---

## Appendix A — Contracts created by `DeployAmoy`

For each module: **implementation** (CREATE) then **ERC1967 proxy** (CREATE). Order:

1. `GovernanceConfig`
2. `WhitelistRegistry` (forwarder in `initialize`)
3. `AssetRegistry`
4. `AssetProviderRegistry` (`AssetRegistry` address in `initialize`)
5. `AssetLedger` (whitelist + forwarder)
6. `EscrowVault` (`AssetLedger`)
7. `TimelockController`
8. `TradeManager` (gov, whitelist, ledger, escrow, timelock, asset + provider registries, forwarder)

`TradeManagerLib` is also deployed (linked library) before / with `TradeManager`.

Then deployer calls `setInitialAdmin` on all eight proxies.

---

## Appendix B — Gas notes

- `foundry.toml` uses `via_ir = true` and `optimizer_runs = 1` so `TradeManager` stays under EIP-170.
- If `transaction gas price below minimum`, raise `--with-gas-price` (e.g. 80 gwei) rather than mixing `--priority-gas-price` with `--legacy`.
- Prefer a paid RPC; public endpoints drop long broadcasts (`dropped from the mempool`). Use `--slow` and `--resume`.
