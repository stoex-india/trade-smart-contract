// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";

/// @title OnboardInvestors
/// @notice Registers investors via admin; optional KYC verify via relayer `verifyKYCFor`.
contract OnboardInvestors is Script {
    function run() external {
        uint256 adminPk = vm.envUint("PRIVATE_KEY");
        uint256 relayerPk = vm.envOr("RELAYER_PRIVATE_KEY", adminPk);

        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));
        WhitelistRegistry registry = WhitelistRegistry(vm.envAddress("WHITELIST_REGISTRY"));
        bool skipKycVerify = vm.envOr("SKIP_KYC_VERIFY", false);

        vm.startBroadcast(adminPk);

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
                registry.adminRegisterUser(userId, investor, kycRef);
                console2.log("Registered investor", investor);
            } else {
                console2.log("adminRegisterUser skipped/already set", investor);
            }
        }

        vm.stopBroadcast();

        vm.startBroadcast(relayerPk);

        for (uint256 i = 1; i <= 20; i++) {
            string memory suffix = vm.toString(i);
            string memory investorKey = string.concat("INVESTOR_", suffix);
            address investor = vm.envOr(investorKey, address(0));
            if (investor == address(0)) continue;

            string memory verifyKycKey = string.concat(investorKey, "_VERIFY_KYC");
            bool verifyKycForInvestor = vm.envOr(verifyKycKey, !skipKycVerify);

            StoexTypes.UserProfile memory profile = registry.getProfile(investor);
            if (verifyKycForInvestor && profile.kycStatus != StoexTypes.KYCStatus.Verified) {
                registry.verifyKYCFor(investor);
                console2.log("KYC verified via relayer", investor);
            } else if (!verifyKycForInvestor) {
                console2.log("verifyKYCFor skipped (per-investor/global flag)", investor);
            } else {
                console2.log("verifyKYCFor skipped/already verified", investor);
            }

            if (!registry.hasRole(StoexRoles.USER_ROLE, investor)) {
                console2.log("WARN: USER_ROLE missing on registry after adminRegisterUser", investor);
            } else {
                console2.log("registry USER_ROLE granted", investor);
            }

            if (!trade.hasRole(StoexRoles.USER_ROLE, investor)) {
                console2.log("WARN: USER_ROLE missing on trade after adminRegisterUser", investor);
            } else {
                console2.log("trade USER_ROLE granted", investor);
            }
        }

        vm.stopBroadcast();
        console2.log("OnboardInvestors completed");
    }
}
