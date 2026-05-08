// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {GovernanceConfig} from "../src/GovernanceConfig.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {GoldNFT} from "../src/GoldNFT.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";

/// @title ConfigureRoles
/// @notice Grants operational roles after deployment. Run with `PRIVATE_KEY` for the **operations admin** (`DEFAULT_ADMIN_ROLE` after `setInitialAdmin`).
/// @dev Example:
/// `forge script script/ConfigureRoles.s.sol:ConfigureRoles --rpc-url amoy --broadcast`
///
/// Required env: `PRIVATE_KEY`, `TRADE_MANAGER`, `GOVERNANCE_CONFIG`, `WHITELIST_REGISTRY`, `GOLD_NFT`, `TIMELOCK_CONTROLLER`
/// Optional role holders (omit or set to zero address to skip): `ROLE_AP`, `ROLE_VP`, `ROLE_AT`, `ROLE_PAP`, `ROLE_AUDITOR`
/// Optional: `RELAYER_SMART_CONTRACT` (or legacy `ERC2771_FORWARDER`) to rotate trusted forwarder on gasless-enabled contracts.
/// @dev Investor onboarding (`registerUser` / `verifyKYC` / `USER_ROLE`) is intentionally handled by `OnboardInvestors.s.sol`.
contract ConfigureRoles is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));
        GovernanceConfig gov = GovernanceConfig(vm.envAddress("GOVERNANCE_CONFIG"));
        WhitelistRegistry registry = WhitelistRegistry(vm.envAddress("WHITELIST_REGISTRY"));
        GoldNFT gold = GoldNFT(vm.envAddress("GOLD_NFT"));
        TimelockController timelock = TimelockController(vm.envAddress("TIMELOCK_CONTROLLER"));

        address ap = vm.envOr("ROLE_AP", address(0));
        address vp = vm.envOr("ROLE_VP", address(0));
        address at = vm.envOr("ROLE_AT", address(0));
        address pap = vm.envOr("ROLE_PAP", address(0));
        address aud = vm.envOr("ROLE_AUDITOR", address(0));
        address forwarder = vm.envOr("RELAYER_SMART_CONTRACT", vm.envOr("ERC2771_FORWARDER", address(0)));

        if (forwarder != address(0)) {
            trade.setTrustedForwarder(forwarder);
            registry.setTrustedForwarder(forwarder);
            gold.setTrustedForwarder(forwarder);
            console2.log("Rotated trusted forwarder", forwarder);
        }

        if (ap != address(0)) {
            trade.grantRole(StoexRoles.AP_ROLE, ap);
            gold.grantRole(StoexRoles.AP_ROLE, ap);
            timelock.grantRole(StoexRoles.AP_ROLE, ap);
        }
        if (vp != address(0)) trade.grantRole(StoexRoles.VP_ROLE, vp);
        if (at != address(0)) {
            trade.grantRole(StoexRoles.AT_ROLE, at);
            gov.grantRole(StoexRoles.AT_ROLE, at);
            registry.grantRole(StoexRoles.AT_ROLE, at);
            timelock.grantRole(StoexRoles.AT_ROLE, at);
        }
        if (pap != address(0)) trade.grantRole(StoexRoles.PAP_ROLE, pap);
        if (aud != address(0)) trade.grantRole(StoexRoles.AUDITOR_ROLE, aud);

        vm.stopBroadcast();
        console2.log("ConfigureRoles completed");
    }
}
