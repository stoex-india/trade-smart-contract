// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {AssetLedger} from "../src/AssetLedger.sol";

/// @title SetTrustedForwarder
contract SetTrustedForwarder is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address forwarder = vm.envAddress("RELAYER_SMART_CONTRACT");
        if (forwarder == address(0)) revert("RELAYER_SMART_CONTRACT is zero");

        vm.startBroadcast(pk);

        TradeManager(vm.envAddress("TRADE_MANAGER")).setTrustedForwarder(forwarder);
        WhitelistRegistry(vm.envAddress("WHITELIST_REGISTRY")).setTrustedForwarder(forwarder);
        AssetLedger(vm.envAddress("ASSET_LEDGER")).setTrustedForwarder(forwarder);

        vm.stopBroadcast();

        console2.log("Trusted forwarder updated to", forwarder);
    }
}
