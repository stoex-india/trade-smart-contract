// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {AssetLedger} from "../src/AssetLedger.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {AssetProviderRegistry} from "../src/AssetProviderRegistry.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";
import {StoexIds} from "../src/libraries/StoexIds.sol";

/// @title RegisterProvider
/// @notice Register a new asset provider, wire GOLD/SILVER, routing, operator, and AP_ROLE grants.
/// @dev Required env: `PRIVATE_KEY` (DEFAULT_ADMIN), `ASSET_PROVIDER_REGISTRY`, `TRADE_MANAGER`,
///      `ASSET_LEDGER`, `TIMELOCK_CONTROLLER`, `PROVIDER_LABEL`, `PROVIDER_NAME`, `PROVIDER_OPERATOR`.
/// @dev Optional: `ASSET_PROVIDER_PAYOUT` (defaults to operator), `REDEEM_SINK` (defaults to 0xdead).
/// @dev Example:
/// `PROVIDER_LABEL=AP2 PROVIDER_NAME=amrapali PROVIDER_OPERATOR=0x3E12... \
///  forge script script/RegisterProvider.s.sol:RegisterProvider --rpc-url amoy --broadcast`
contract RegisterProvider is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        AssetProviderRegistry pr = AssetProviderRegistry(vm.envAddress("ASSET_PROVIDER_REGISTRY"));
        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));
        AssetLedger ledger = AssetLedger(vm.envAddress("ASSET_LEDGER"));
        TimelockController timelock = TimelockController(vm.envAddress("TIMELOCK_CONTROLLER"));

        bytes32 providerId = keccak256(bytes(vm.envString("PROVIDER_LABEL")));
        string memory providerName = vm.envString("PROVIDER_NAME");
        address operator = vm.envAddress("PROVIDER_OPERATOR");
        address payout = vm.envOr("ASSET_PROVIDER_PAYOUT", operator);
        address redeemSink = vm.envOr("REDEEM_SINK", address(0x000000000000000000000000000000000000dEaD));

        if (!pr.isProviderActive(providerId)) {
            pr.registerProvider(providerId, providerName);
            console2.log("registerProvider", vm.envString("PROVIDER_LABEL"), providerName);
        } else {
            console2.log("provider already active", vm.envString("PROVIDER_LABEL"));
        }

        pr.setProviderAsset(providerId, StoexIds.GOLD, true);
        pr.setProviderAsset(providerId, StoexIds.SILVER, true);
        pr.setAssetRouting(providerId, StoexIds.GOLD, payout, redeemSink);
        pr.setAssetRouting(providerId, StoexIds.SILVER, payout, redeemSink);
        pr.addProviderOperator(providerId, operator);

        if (!trade.hasRole(StoexRoles.AP_ROLE, operator)) trade.grantRole(StoexRoles.AP_ROLE, operator);
        if (!ledger.hasRole(StoexRoles.AP_ROLE, operator)) ledger.grantRole(StoexRoles.AP_ROLE, operator);
        if (!timelock.hasRole(StoexRoles.AP_ROLE, operator)) timelock.grantRole(StoexRoles.AP_ROLE, operator);

        vm.stopBroadcast();
        console2.log("RegisterProvider completed for", vm.envString("PROVIDER_LABEL"), operator);
    }
}
