// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {GovernanceConfig} from "../src/GovernanceConfig.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {AssetLedger} from "../src/AssetLedger.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";

/// @title ConfigureRoles
contract ConfigureRoles is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));
        GovernanceConfig gov = GovernanceConfig(vm.envAddress("GOVERNANCE_CONFIG"));
        WhitelistRegistry registry = WhitelistRegistry(vm.envAddress("WHITELIST_REGISTRY"));
        AssetLedger ledger = AssetLedger(vm.envAddress("ASSET_LEDGER"));
        TimelockController timelock = TimelockController(vm.envAddress("TIMELOCK_CONTROLLER"));

        address ap = vm.envOr("ROLE_AP", address(0));
        address vp = vm.envOr("ROLE_VP", address(0));
        address at = vm.envOr("ROLE_AT", address(0));
        address pap = vm.envOr("ROLE_PAP", address(0));
        address aud = vm.envOr("ROLE_AUDITOR", address(0));
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

        if (ap != address(0)) {
            if (!trade.hasRole(StoexRoles.AP_ROLE, ap)) trade.grantRole(StoexRoles.AP_ROLE, ap);
            if (!ledger.hasRole(StoexRoles.AP_ROLE, ap)) ledger.grantRole(StoexRoles.AP_ROLE, ap);
            if (!timelock.hasRole(StoexRoles.AP_ROLE, ap)) timelock.grantRole(StoexRoles.AP_ROLE, ap);
        }
        if (vp != address(0) && !trade.hasRole(StoexRoles.VP_ROLE, vp)) trade.grantRole(StoexRoles.VP_ROLE, vp);
        if (at != address(0)) {
            if (!trade.hasRole(StoexRoles.AT_ROLE, at)) trade.grantRole(StoexRoles.AT_ROLE, at);
            if (!gov.hasRole(StoexRoles.AT_ROLE, at)) gov.grantRole(StoexRoles.AT_ROLE, at);
            if (!registry.hasRole(StoexRoles.AT_ROLE, at)) registry.grantRole(StoexRoles.AT_ROLE, at);
            if (!timelock.hasRole(StoexRoles.AT_ROLE, at)) timelock.grantRole(StoexRoles.AT_ROLE, at);
        }
        if (pap != address(0) && !trade.hasRole(StoexRoles.PAP_ROLE, pap)) trade.grantRole(StoexRoles.PAP_ROLE, pap);
        if (aud != address(0) && !trade.hasRole(StoexRoles.AUDITOR_ROLE, aud)) {
            trade.grantRole(StoexRoles.AUDITOR_ROLE, aud);
        }

        vm.stopBroadcast();
        console2.log("ConfigureRoles completed");
    }
}
