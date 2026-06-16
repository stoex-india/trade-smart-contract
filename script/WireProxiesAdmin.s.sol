// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {GoldNFT} from "../src/GoldNFT.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";

/// @title WireProxiesAdmin
/// @notice Run with the **admin** wallet key when `INITIAL_ADMIN` differed from the deployer in `DeployAmoy`.
/// @dev Required env: `PRIVATE_KEY` (admin’s key for this run), `TRADE_MANAGER`, `ESCROW_VAULT`,
/// `TIMELOCK_CONTROLLER`, `GOLD_NFT`. Optional: `ASSET_PROVIDER_PAYOUT`, `REDEEM_SINK`, `VAULT_BOOKKEEPING` (defaults match DeployAmoy).
/// @dev Example:
/// `forge script script/WireProxiesAdmin.s.sol:WireProxiesAdmin --rpc-url amoy --broadcast`
contract WireProxiesAdmin is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);

        address tradeAddr = vm.envAddress("TRADE_MANAGER");
        address escrowAddr = vm.envAddress("ESCROW_VAULT");
        address timelockAddr = vm.envAddress("TIMELOCK_CONTROLLER");
        address goldAddr = vm.envAddress("GOLD_NFT");
        address registryAddr = vm.envAddress("WHITELIST_REGISTRY");

        address apPayout = vm.envOr("ASSET_PROVIDER_PAYOUT", admin);
        address rSink = vm.envOr("REDEEM_SINK", address(0x000000000000000000000000000000000000dEaD));
        address vaultBk = vm.envOr("VAULT_BOOKKEEPING", admin);

        vm.startBroadcast(pk);

        TradeManager trade = TradeManager(tradeAddr);
        trade.setRoutingAddresses(apPayout, rSink, vaultBk);

        EscrowVault(escrowAddr).setTradeManager(tradeAddr);
        TimelockController(timelockAddr).setTradeManager(tradeAddr);
        GoldNFT(goldAddr).grantRole(StoexRoles.TRADE_MANAGER_ROLE, tradeAddr);
        WhitelistRegistry(registryAddr).setTradeManager(tradeAddr);

        vm.stopBroadcast();

        console2.log("WireProxiesAdmin completed for admin", admin);
    }
}
