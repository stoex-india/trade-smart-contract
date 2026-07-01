// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {AssetLedger} from "../src/AssetLedger.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";

/// @title WireProxiesAdmin
/// @notice Run with the **admin** wallet when `INITIAL_ADMIN` differed from deployer in `DeployAmoy`.
contract WireProxiesAdmin is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);

        address tradeAddr = vm.envAddress("TRADE_MANAGER");
        address escrowAddr = vm.envAddress("ESCROW_VAULT");
        address timelockAddr = vm.envAddress("TIMELOCK_CONTROLLER");
        address ledgerAddr = vm.envAddress("ASSET_LEDGER");
        address registryAddr = vm.envAddress("WHITELIST_REGISTRY");

        vm.startBroadcast(pk);

        EscrowVault(escrowAddr).setTradeManager(tradeAddr);
        TimelockController(timelockAddr).setTradeManager(tradeAddr);
        AssetLedger(ledgerAddr).grantRole(StoexRoles.TRADE_MANAGER_ROLE, tradeAddr);
        WhitelistRegistry(registryAddr).setTradeManager(tradeAddr);

        vm.stopBroadcast();

        console2.log("WireProxiesAdmin completed for admin", admin);
        tradeAddr;
    }
}
