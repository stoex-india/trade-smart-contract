// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {GovernanceConfig} from "../src/GovernanceConfig.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {GoldNFT} from "../src/GoldNFT.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {TradeManager} from "../src/TradeManager.sol";

/// @title SetInitialAdmins
/// @notice Deployer-only: calls `setInitialAdmin` on all core proxies after deployment (if not batched in `DeployAmoy`).
/// @dev Required env: `PRIVATE_KEY` = deployer, `INITIAL_ADMIN`, plus `GOVERNANCE_CONFIG`, `WHITELIST_REGISTRY`, `GOLD_NFT`,
/// `ESCROW_VAULT`, `TIMELOCK_CONTROLLER`, `TRADE_MANAGER`.
contract SetInitialAdmins is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address initialAdmin = vm.envAddress("INITIAL_ADMIN");

        vm.startBroadcast(pk);

        GovernanceConfig(vm.envAddress("GOVERNANCE_CONFIG")).setInitialAdmin(initialAdmin);
        WhitelistRegistry(vm.envAddress("WHITELIST_REGISTRY")).setInitialAdmin(initialAdmin);
        GoldNFT(vm.envAddress("GOLD_NFT")).setInitialAdmin(initialAdmin);
        EscrowVault(vm.envAddress("ESCROW_VAULT")).setInitialAdmin(initialAdmin);
        TimelockController(vm.envAddress("TIMELOCK_CONTROLLER")).setInitialAdmin(initialAdmin);
        TradeManager(vm.envAddress("TRADE_MANAGER")).setInitialAdmin(initialAdmin);

        vm.stopBroadcast();

        console2.log("setInitialAdmin completed for", initialAdmin);
    }
}
