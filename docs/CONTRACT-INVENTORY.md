# STOEX contract inventory

Living address book for **Polygon Amoy (testnet)** and **Polygon PoS (mainnet)**.  
Update this file in the same PR / change ticket as any deploy or UUPS upgrade.

- Explorers: [Amoy Polygonscan](https://amoy.polygonscan.com) · [Polygonscan](https://polygonscan.com)
- Integration: [FRONTEND_INTEGRATION.md](FRONTEND_INTEGRATION.md)
- Deploy: [MAINNET-DEPLOYMENT-SOP.md](MAINNET-DEPLOYMENT-SOP.md)

**Always integrate against proxy addresses**, not implementations. Implementations change on upgrade; proxies do not.

---

## Network index

| Network | Chain ID | Native gas | Explorer | RPC env | Status |
|---------|----------|------------|----------|---------|--------|
| Polygon Amoy | `80002` | POL (test) | https://amoy.polygonscan.com | `AMOY_RPC_URL` | **Live** (audit-remediation redeploy 2026-08-10, `version = 4`) |
| Polygon mainnet | `137` | POL | https://polygonscan.com | `POLYGON_RPC_URL` | **Not deployed** — fill tables after SOP |

---

## Canonical IDs (both networks)

| Label | `bytes32` (`keccak256`) |
|-------|-------------------------|
| GOLD | `0xdbd17891fc491ac6717dd01ab1f90f82509f1f2e91cd5066f68805860fbdeb72` |
| SILVER | `0x75e02a3ee626f5d4b8bc98cc8de5b102ee067608b6066832ffdc71f78445ac2b` |
| AP1 (MMTC) | `0x18b117340645cfb38a7414f6a51f090965f4e22ead292d9dad633e05e91ff811` |

Amounts: **micrograms** (`1 g = 1_000_000` µg).

---

# A. Polygon Amoy (testnet)

| Field | Value |
|-------|--------|
| Deployed | 2026-08-10 |
| Git / release | Femto remediation, contract `version = 4` |
| Broadcast | `broadcast/DeployAmoy.s.sol/80002/` |
| On-chain admin / deployer | `0xDb79cCBfFB614BCBf636a724D2E373cbAE36287d` |
| Default provider | AP1 / **MMTC** |
| Provider operator (metadata) | `0x77C1a84070bF6D4FF64602D467878EFC809C98DD` |
| Sell payout (Amoy) | `0x77C1a84070bF6D4FF64602D467878EFC809C98DD` |

### A.1 Proxies (use these)

| Contract | Address | Polygonscan |
|----------|---------|-------------|
| GovernanceConfig | `0x85636CBf6639366d3D72Aa7Bc9375F700685B05D` | [View](https://amoy.polygonscan.com/address/0x85636CBf6639366d3D72Aa7Bc9375F700685B05D) |
| AssetRegistry | `0x53E5FEa57B8854DE17214714e13b565b8a637031` | [View](https://amoy.polygonscan.com/address/0x53E5FEa57B8854DE17214714e13b565b8a637031) |
| AssetProviderRegistry | `0x805Ae698602028A3f7fA3A9DF36FCB3595B6db7C` | [View](https://amoy.polygonscan.com/address/0x805Ae698602028A3f7fA3A9DF36FCB3595B6db7C) |
| WhitelistRegistry | `0x1Dd88BD5Bf91c454894Be56D103EeDB75A7aF85C` | [View](https://amoy.polygonscan.com/address/0x1Dd88BD5Bf91c454894Be56D103EeDB75A7aF85C) |
| AssetLedger | `0x464e01e2AbCA026DF92a612318D71cf20b43D4c2` | [View](https://amoy.polygonscan.com/address/0x464e01e2AbCA026DF92a612318D71cf20b43D4c2) |
| EscrowVault | `0xCdD50B2D88d17DB7D4E161a08185931031aBe3C0` | [View](https://amoy.polygonscan.com/address/0xCdD50B2D88d17DB7D4E161a08185931031aBe3C0) |
| TimelockController | `0x2A6EDE57E6F6864F2d406E8a0BB04964d4bc010a` | [View](https://amoy.polygonscan.com/address/0x2A6EDE57E6F6864F2d406E8a0BB04964d4bc010a) |
| TradeManager | `0x5f1553F974F5Ae137Af52487EaCE01c8164cc9Cf` | [View](https://amoy.polygonscan.com/address/0x5f1553F974F5Ae137Af52487EaCE01c8164cc9Cf) |

### A.2 Implementations (UUPS targets as of 2026-08-10 deploy)

Confirm with EIP-1967 slot `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` after any upgrade.

| Contract | Implementation | Polygonscan |
|----------|----------------|-------------|
| GovernanceConfig | `0x8Cd8fd5000f4D048f7cad50336633eE2b7Eb0f11` | [View](https://amoy.polygonscan.com/address/0x8Cd8fd5000f4D048f7cad50336633eE2b7Eb0f11) |
| WhitelistRegistry | `0x2E5988C7863C05363366eFf8ed32bF0177e3f1b4` | [View](https://amoy.polygonscan.com/address/0x2E5988C7863C05363366eFf8ed32bF0177e3f1b4) |
| AssetRegistry | `0x34370885969E7FA67CB5F2b9Ac284494b5386e9e` | [View](https://amoy.polygonscan.com/address/0x34370885969E7FA67CB5F2b9Ac284494b5386e9e) |
| AssetProviderRegistry | `0x01b80f1D8C83564105326D9b5e00dbBbD8126848` | [View](https://amoy.polygonscan.com/address/0x01b80f1D8C83564105326D9b5e00dbBbD8126848) |
| AssetLedger | `0xB363e2F0679fd089FF2E01781F999742472F3C1d` | [View](https://amoy.polygonscan.com/address/0xB363e2F0679fd089FF2E01781F999742472F3C1d) |
| EscrowVault | `0xb43BE3c53AF9D5C1415D640330c14d3DAb220ef1` | [View](https://amoy.polygonscan.com/address/0xb43BE3c53AF9D5C1415D640330c14d3DAb220ef1) |
| TimelockController | `0xCB3bDBA9c73E4FC9DaB5c4A757B368a7e6A63324` | [View](https://amoy.polygonscan.com/address/0xCB3bDBA9c73E4FC9DaB5c4A757B368a7e6A63324) |
| TradeManager | `0x3d4C36a5e22615e2747f667F770a82804Bb0810e` | [View](https://amoy.polygonscan.com/address/0x3d4C36a5e22615e2747f667F770a82804Bb0810e) |
| TradeManagerLib (linked library) | `0x917261Bd86BCE81A7481825788064ac6B8343A7f` | [View](https://amoy.polygonscan.com/address/0x917261Bd86BCE81A7481825788064ac6B8343A7f) |

### A.3 External (Tresori) — Amoy

| Name | Address | Polygonscan |
|------|---------|-------------|
| Relayer / trusted forwarder (`RELAYER_SMART_CONTRACT`) | `0xB9CBD815098cc3d6A348bDfed995af91e2298d6D` | [View](https://amoy.polygonscan.com/address/0xB9CBD815098cc3d6A348bDfed995af91e2298d6D) |
| Facilitator (`FACILITATOR_SMART_CONTRACT`) | `0x9DE37157464E5Ecf8FD0AB0d88D2B08c3cdfFf6D` | [View](https://amoy.polygonscan.com/address/0x9DE37157464E5Ecf8FD0AB0d88D2B08c3cdfFf6D) |

### A.4 Ops wallets — Amoy

| Role | Address | Polygonscan |
|------|---------|-------------|
| Deployer + current admin | `0xDb79cCBfFB614BCBf636a724D2E373cbAE36287d` | [View](https://amoy.polygonscan.com/address/0xDb79cCBfFB614BCBf636a724D2E373cbAE36287d) |
| Provider operator / payout | `0x77C1a84070bF6D4FF64602D467878EFC809C98DD` | [View](https://amoy.polygonscan.com/address/0x77C1a84070bF6D4FF64602D467878EFC809C98DD) |

Older Amoy proxies from before 2026-08-10 are **obsolete**. Do not point clients at them. Users must re-onboard on the whitelist above.

---

# B. Polygon mainnet

**Status:** not deployed. After [MAINNET-DEPLOYMENT-SOP.md](MAINNET-DEPLOYMENT-SOP.md), replace every `TBD` and set status to Live.

| Field | Value |
|-------|--------|
| Deployed | TBD |
| Git tag | TBD |
| Broadcast | `broadcast/DeployAmoy.s.sol/137/` |
| On-chain admin | TBD |
| Deployer | TBD |
| Default provider | TBD (`AP1` / MMTC expected) |
| Relayer (Tresori mainnet) | TBD — do not assume the Amoy address |

### B.1 Proxies (use these)

| Contract | Address | Polygonscan |
|----------|---------|-------------|
| GovernanceConfig | TBD | https://polygonscan.com/address/TBD |
| AssetRegistry | TBD | https://polygonscan.com/address/TBD |
| AssetProviderRegistry | TBD | https://polygonscan.com/address/TBD |
| WhitelistRegistry | TBD | https://polygonscan.com/address/TBD |
| AssetLedger | TBD | https://polygonscan.com/address/TBD |
| EscrowVault | TBD | https://polygonscan.com/address/TBD |
| TimelockController | TBD | https://polygonscan.com/address/TBD |
| TradeManager | TBD | https://polygonscan.com/address/TBD |

After deploy, links look like: `https://polygonscan.com/address/0x…`

### B.2 Implementations

| Contract | Implementation | Polygonscan |
|----------|----------------|-------------|
| GovernanceConfig | TBD | https://polygonscan.com/address/TBD |
| WhitelistRegistry | TBD | https://polygonscan.com/address/TBD |
| AssetRegistry | TBD | https://polygonscan.com/address/TBD |
| AssetProviderRegistry | TBD | https://polygonscan.com/address/TBD |
| AssetLedger | TBD | https://polygonscan.com/address/TBD |
| EscrowVault | TBD | https://polygonscan.com/address/TBD |
| TimelockController | TBD | https://polygonscan.com/address/TBD |
| TradeManager | TBD | https://polygonscan.com/address/TBD |
| TradeManagerLib | TBD | https://polygonscan.com/address/TBD |

### B.3 External (Tresori) — mainnet

| Name | Address | Polygonscan |
|------|---------|-------------|
| Relayer / trusted forwarder | TBD | https://polygonscan.com/address/TBD |
| Facilitator | TBD | https://polygonscan.com/address/TBD |

### B.4 Ops wallets — mainnet

| Role | Address | Polygonscan |
|------|---------|-------------|
| Deployer | TBD | https://polygonscan.com/address/TBD |
| Admin (`DEFAULT_ADMIN_ROLE`) | TBD | https://polygonscan.com/address/TBD |
| Sell payout | TBD | https://polygonscan.com/address/TBD |
| Redeem sink | TBD | https://polygonscan.com/address/TBD |
| Provider operator (optional) | TBD | https://polygonscan.com/address/TBD |

---

## How to refresh this sheet

1. Proxies: copy from `DeployAmoy` console / `broadcast/DeployAmoy.s.sol/<chainId>/run-latest.json` (`ERC1967Proxy` rows, in deploy order).
2. Implementations: matching non-proxy `CREATE` rows, or `cast storage <proxy> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`.
3. Wrap each address as `https://amoy.polygonscan.com/address/<addr>` or `https://polygonscan.com/address/<addr>`.
4. Bump “Status” and the date line. Never edit Amoy rows to hold mainnet addresses — keep both sections.

Checksum addresses (EIP-55) before publishing:

```shell
cast --to-checksum-address 0x...
```
