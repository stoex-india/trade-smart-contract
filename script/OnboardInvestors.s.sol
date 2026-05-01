// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";

/// @title OnboardInvestors
/// @notice Registers investors, optionally verifies KYC, then grants USER_ROLE on registry + trade manager.
/// @dev Example:
/// `forge script script/OnboardInvestors.s.sol:OnboardInvestors --rpc-url amoy --broadcast`
///
/// Required env:
/// - `PRIVATE_KEY` (must hold `DEFAULT_ADMIN_ROLE` on registry / trade), `TRADE_MANAGER`, `WHITELIST_REGISTRY`
///
/// Optional:
/// - `SKIP_KYC_VERIFY=true` — global default: leave users in **Pending** KYC (restricted buy only).
/// - `INVESTOR_<n>_VERIFY_KYC=true|false` — per-investor override; takes precedence over `SKIP_KYC_VERIFY`.
///
/// Optional investor slots:
/// - `INVESTOR_1` .. `INVESTOR_20` (wallet addresses)
/// - `INVESTOR_1_KYC_REF` .. `INVESTOR_20_KYC_REF` (defaults to `KYC-<n>`)
///
/// User id generation:
/// - `userId = keccak256("INVESTOR_<n>|<wallet>")`
/// This keeps onboarding deterministic for test/dev while avoiding extra env plumbing.
contract OnboardInvestors is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));
        WhitelistRegistry registry = WhitelistRegistry(vm.envAddress("WHITELIST_REGISTRY"));
        bool skipKycVerify = vm.envOr("SKIP_KYC_VERIFY", false);

        for (uint256 i = 1; i <= 20; i++) {
            string memory suffix = vm.toString(i);
            string memory investorKey = string.concat("INVESTOR_", suffix);
            address investor = vm.envOr(investorKey, address(0));
            if (investor == address(0)) continue;

            bytes32 userId = keccak256(abi.encodePacked(investorKey, "|", investor));

            string memory kycRefKey = string.concat(investorKey, "_KYC_REF");
            string memory kycRef = vm.envOr(kycRefKey, string.concat("KYC-", suffix));

            StoexTypes.UserProfile memory profile = registry.getProfile(investor);
            if (profile.registeredAt == 0) {
                registry.registerUser(userId, investor, kycRef);
                console2.log("Registered investor", investor);
            } else {
                console2.log("registerUser skipped/already set", investor);
            }

            string memory verifyKycKey = string.concat(investorKey, "_VERIFY_KYC");
            bool verifyKycForInvestor = vm.envOr(verifyKycKey, !skipKycVerify);

            profile = registry.getProfile(investor);
            if (verifyKycForInvestor && profile.kycStatus != StoexTypes.KYCStatus.Verified) {
                registry.verifyKYC(investor);
                console2.log("KYC verified", investor);
            } else if (!verifyKycForInvestor) {
                console2.log("verifyKYC skipped (per-investor/global flag)", investor);
            } else {
                console2.log("verifyKYC skipped/already verified", investor);
            }

            if (!registry.hasRole(StoexRoles.USER_ROLE, investor)) {
                registry.grantRole(StoexRoles.USER_ROLE, investor);
                console2.log("Granted USER_ROLE on registry", investor);
            } else {
                console2.log("registry USER_ROLE already granted", investor);
            }

            if (!trade.hasRole(StoexRoles.USER_ROLE, investor)) {
                trade.grantRole(StoexRoles.USER_ROLE, investor);
                console2.log("Granted USER_ROLE on trade manager", investor);
            } else {
                console2.log("trade USER_ROLE already granted", investor);
            }
        }

        vm.stopBroadcast();
        console2.log("OnboardInvestors completed");
    }
}
