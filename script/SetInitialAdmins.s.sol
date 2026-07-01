// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {GovernanceConfig} from "../src/GovernanceConfig.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {AssetProviderRegistry} from "../src/AssetProviderRegistry.sol";
import {AssetLedger} from "../src/AssetLedger.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {TradeManager} from "../src/TradeManager.sol";

/// @title SetInitialAdmins
contract SetInitialAdmins is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address initialAdmin = vm.envAddress("INITIAL_ADMIN");

        vm.startBroadcast(pk);

        GovernanceConfig(vm.envAddress("GOVERNANCE_CONFIG")).setInitialAdmin(initialAdmin);
        WhitelistRegistry(vm.envAddress("WHITELIST_REGISTRY")).setInitialAdmin(initialAdmin);
        AssetRegistry(vm.envAddress("ASSET_REGISTRY")).setInitialAdmin(initialAdmin);
        AssetProviderRegistry(vm.envAddress("ASSET_PROVIDER_REGISTRY")).setInitialAdmin(initialAdmin);
        AssetLedger(vm.envAddress("ASSET_LEDGER")).setInitialAdmin(initialAdmin);
        EscrowVault(vm.envAddress("ESCROW_VAULT")).setInitialAdmin(initialAdmin);
        TimelockController(vm.envAddress("TIMELOCK_CONTROLLER")).setInitialAdmin(initialAdmin);
        TradeManager(vm.envAddress("TRADE_MANAGER")).setInitialAdmin(initialAdmin);

        vm.stopBroadcast();

        console2.log("setInitialAdmin completed for", initialAdmin);
    }
}
