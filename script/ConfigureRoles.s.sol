// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {AssetLedger} from "../src/AssetLedger.sol";

/// @title ConfigureRoles
/// @notice V1: rotate trusted forwarder only. Trade path uses Admin + User roles (no AP/VP/AT/PAP grants).
contract ConfigureRoles is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));
        WhitelistRegistry registry = WhitelistRegistry(vm.envAddress("WHITELIST_REGISTRY"));
        AssetLedger ledger = AssetLedger(vm.envAddress("ASSET_LEDGER"));

        address forwarder = vm.envOr("RELAYER_SMART_CONTRACT", vm.envOr("ERC2771_FORWARDER", address(0)));

        if (forwarder != address(0)) {
            if (trade.trustedForwarder() != forwarder) {
                trade.setTrustedForwarder(forwarder);
                console2.log("TradeManager trusted forwarder updated", forwarder);
            }
            if (registry.trustedForwarder() != forwarder) {
                registry.setTrustedForwarder(forwarder);
                console2.log("WhitelistRegistry trusted forwarder updated", forwarder);
            }
            if (ledger.trustedForwarder() != forwarder) {
                ledger.setTrustedForwarder(forwarder);
                console2.log("AssetLedger trusted forwarder updated", forwarder);
            }
        }

        vm.stopBroadcast();
        console2.log("ConfigureRoles completed (forwarder only; V1 has no third-party trade roles)");
    }
}
