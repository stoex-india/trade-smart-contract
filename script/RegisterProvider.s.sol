// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {AssetProviderRegistry} from "../src/AssetProviderRegistry.sol";
import {StoexIds} from "../src/libraries/StoexIds.sol";

/// @title RegisterProvider
/// @notice Register a new asset provider, wire GOLD/SILVER, routing, and operator (V1 — no AP_ROLE grants).
/// @dev Required env: `PRIVATE_KEY` (DEFAULT_ADMIN), `ASSET_PROVIDER_REGISTRY`,
///      `PROVIDER_LABEL`, `PROVIDER_NAME`, `PROVIDER_OPERATOR`.
/// @dev Optional: `ASSET_PROVIDER_PAYOUT` (defaults to operator), `REDEEM_SINK` (defaults to 0xdead).
contract RegisterProvider is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        AssetProviderRegistry pr = AssetProviderRegistry(vm.envAddress("ASSET_PROVIDER_REGISTRY"));

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

        vm.stopBroadcast();
        console2.log("RegisterProvider completed for", vm.envString("PROVIDER_LABEL"), operator);
    }
}
