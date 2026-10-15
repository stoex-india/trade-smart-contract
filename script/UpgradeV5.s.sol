// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {GovernanceConfig} from "../src/GovernanceConfig.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {AssetLedger} from "../src/AssetLedger.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {AssetProviderRegistry} from "../src/AssetProviderRegistry.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {TradeManager} from "../src/TradeManager.sol";

/// @title UpgradeV5
/// @notice Deploy v5 implementations and UUPS-upgrade existing proxies (OPS_ADMIN, transferAsset, reconcile).
/// @dev Signer must hold DEFAULT_ADMIN_ROLE on every proxy (Amoy: 0xDb79…).
///      `initializeV5` on GovernanceConfig seeds OPS_RECONCILE_TRADE. If gov is already v5, skip
///      that initializer and call `setOpsCapability(keccak256("OPS_RECONCILE_TRADE"), true)`.
contract UpgradeV5 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address govProxy = vm.envAddress("GOVERNANCE_CONFIG");
        address wrProxy = vm.envAddress("WHITELIST_REGISTRY");
        address ledgerProxy = vm.envAddress("ASSET_LEDGER");
        address assetRegProxy = vm.envAddress("ASSET_REGISTRY");
        address providerProxy = vm.envAddress("ASSET_PROVIDER_REGISTRY");
        address timelockProxy = vm.envAddress("TIMELOCK_CONTROLLER");
        address tradeProxy = vm.envAddress("TRADE_MANAGER");

        vm.startBroadcast(pk);

        GovernanceConfig govImpl = new GovernanceConfig();
        GovernanceConfig(govProxy).upgradeToAndCall(address(govImpl), abi.encodeCall(GovernanceConfig.initializeV5, ()));

        TradeManager tradeImpl = new TradeManager();
        TradeManager(tradeProxy).upgradeToAndCall(address(tradeImpl), abi.encodeCall(TradeManager.initializeV5, ()));

        WhitelistRegistry wrImpl = new WhitelistRegistry();
        WhitelistRegistry(wrProxy)
            .upgradeToAndCall(address(wrImpl), abi.encodeCall(WhitelistRegistry.initializeV5, (govProxy)));

        AssetLedger ledgerImpl = new AssetLedger();
        AssetLedger(ledgerProxy)
            .upgradeToAndCall(address(ledgerImpl), abi.encodeCall(AssetLedger.initializeV5, (govProxy)));

        AssetRegistry arImpl = new AssetRegistry();
        AssetRegistry(assetRegProxy)
            .upgradeToAndCall(address(arImpl), abi.encodeCall(AssetRegistry.initializeV5, (govProxy)));

        AssetProviderRegistry prImpl = new AssetProviderRegistry();
        AssetProviderRegistry(providerProxy)
            .upgradeToAndCall(address(prImpl), abi.encodeCall(AssetProviderRegistry.initializeV5, (govProxy)));

        TimelockController tlImpl = new TimelockController();
        TimelockController(timelockProxy)
            .upgradeToAndCall(address(tlImpl), abi.encodeCall(TimelockController.initializeV5, (govProxy)));

        vm.stopBroadcast();

        console2.log("GovernanceConfig impl", address(govImpl));
        console2.log("TradeManager impl", address(tradeImpl));
        console2.log("WhitelistRegistry impl", address(wrImpl));
        console2.log("AssetLedger impl", address(ledgerImpl));
        console2.log("AssetRegistry impl", address(arImpl));
        console2.log("AssetProviderRegistry impl", address(prImpl));
        console2.log("TimelockController impl", address(tlImpl));
    }
}
