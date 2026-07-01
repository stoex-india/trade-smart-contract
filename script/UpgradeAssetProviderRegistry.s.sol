// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {AssetProviderRegistry} from "../src/AssetProviderRegistry.sol";

/// @title UpgradeAssetProviderRegistry
/// @notice Deploy new implementation and UUPS-upgrade the proxy (adds `updateProviderName`).
/// @dev Requires admin `PRIVATE_KEY` (`DEFAULT_ADMIN_ROLE` on the proxy).
contract UpgradeAssetProviderRegistry is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address proxy = vm.envAddress("ASSET_PROVIDER_REGISTRY");

        vm.startBroadcast(pk);

        AssetProviderRegistry impl = new AssetProviderRegistry();
        AssetProviderRegistry(proxy).upgradeToAndCall(address(impl), "");

        vm.stopBroadcast();

        console2.log("AssetProviderRegistry proxy", proxy);
        console2.log("New implementation", address(impl));
    }
}
