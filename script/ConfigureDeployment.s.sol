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
import {StoexRoles} from "../src/libraries/StoexRoles.sol";
import {StoexIds} from "../src/libraries/StoexIds.sol";

/// @title ConfigureDeployment
/// @notice Admin phase after `DeployAmoy` when `INITIAL_ADMIN != deployer`.
/// @dev Required env: admin `PRIVATE_KEY`, proxy addresses, `RELAYER_SMART_CONTRACT`.
contract ConfigureDeployment is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);
        address initialAdmin = vm.envAddress("INITIAL_ADMIN");
        if (admin != initialAdmin) revert("PRIVATE_KEY must be INITIAL_ADMIN");

        address gov = vm.envAddress("GOVERNANCE_CONFIG");
        address registry = vm.envAddress("WHITELIST_REGISTRY");
        address assetReg = vm.envAddress("ASSET_REGISTRY");
        address providerReg = vm.envAddress("ASSET_PROVIDER_REGISTRY");
        address ledger = vm.envAddress("ASSET_LEDGER");
        address escrow = vm.envAddress("ESCROW_VAULT");
        address timelock = vm.envAddress("TIMELOCK_CONTROLLER");
        address trade = vm.envAddress("TRADE_MANAGER");

        address apOperator = vm.envOr("ROLE_AP", address(0));
        address apPayout = vm.envOr("ASSET_PROVIDER_PAYOUT", admin);
        address rSink = vm.envOr("REDEEM_SINK", address(0x000000000000000000000000000000000000dEaD));
        bytes32 providerId = keccak256(bytes(vm.envOr("DEFAULT_PROVIDER_LABEL", string("AP1"))));

        vm.startBroadcast(pk);

        AssetRegistry(assetReg).registerAsset(StoexIds.GOLD, "AU", "Gold", 6);
        AssetRegistry(assetReg).registerAsset(StoexIds.SILVER, "AG", "Silver", 6);

        AssetProviderRegistry pr = AssetProviderRegistry(providerReg);
        pr.registerProvider(providerId, vm.envOr("DEFAULT_PROVIDER_NAME", string("MMTC")));
        if (apOperator != address(0)) {
            pr.addProviderOperator(providerId, apOperator);
        }
        pr.setProviderAsset(providerId, StoexIds.GOLD, true);
        pr.setProviderAsset(providerId, StoexIds.SILVER, true);
        pr.setAssetRouting(providerId, StoexIds.GOLD, apPayout, rSink);
        pr.setAssetRouting(providerId, StoexIds.SILVER, apPayout, rSink);

        EscrowVault(escrow).setTradeManager(trade);
        TimelockController(timelock).setTradeManager(trade);
        AssetLedger(ledger).grantRole(StoexRoles.TRADE_MANAGER_ROLE, trade);
        WhitelistRegistry(registry).setTradeManager(trade);

        vm.stopBroadcast();

        console2.log("ConfigureDeployment completed for", admin);
        gov;
    }
}
