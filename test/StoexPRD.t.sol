// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexFixture} from "./helpers/StoexFixture.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {AssetLedger} from "../src/AssetLedger.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {GovernanceConfig} from "../src/GovernanceConfig.sol";
import {StoexRelayerGate} from "../src/base/StoexRelayerGate.sol";

/// @title StoexPRD
/// @notice Integration tests for V1 flows: buy / sell / redeem with admin-only settlement.
contract StoexPRDTest is StoexFixture {
    uint256 internal constant UG_PER_G = 1_000_000;

    function test_buy_flow_credits_circulating() public {
        uint256 mg = 100 * UG_PER_G;
        _executeBuy(user, GOLD, AP1, mg);
        assertEq(ledger.userHolding(user, GOLD, AP1), mg);
        assertEq(ledger.circulatingSupply(GOLD, AP1), mg);
        assertEq(ledger.totalCirculating(GOLD), mg);
        assertEq(ledger.lifetimeIssued(GOLD, AP1), mg);
        assertTrue(ledger.tokenIdByBeneficiary(user, GOLD) != 0);
    }

    function test_sell_flow_admin_execute_with_settlement_ref() public {
        _executeBuy(user, GOLD, AP1, 500 * UG_PER_G);
        uint256 sellG = 200 * UG_PER_G;
        uint256 rid = _sellRequest(user, GOLD, AP1, sellG);
        bytes32 settlement = bytes32(uint256(0xabc));
        _adminExecute(rid, settlement);
        assertEq(ledger.userHolding(user, GOLD, AP1), 300 * UG_PER_G);
        assertEq(ledger.circulatingSupply(GOLD, AP1), 300 * UG_PER_G);
        assertEq(ledger.lifetimeSoldBack(GOLD, AP1), sellG);
        assertEq(ledger.lifetimeIssued(GOLD, AP1), 500 * UG_PER_G);
        assertEq(escrow.getLockedAmount(user, GOLD, AP1), 0);
        assertEq(trade.getRequest(rid).paymentRefId, settlement);
    }

    function test_redeem_flow_admin_execute() public {
        _executeBuy(user, GOLD, AP1, 500 * UG_PER_G);
        uint256 redeemG = 50 * UG_PER_G;
        uint256 rid = _redeemRequest(user, GOLD, AP1, redeemG);
        _adminExecute(rid, bytes32(uint256(0xdef)));
        assertEq(ledger.userHolding(user, GOLD, AP1), 450 * UG_PER_G);
        assertEq(ledger.lifetimeRedeemed(GOLD, AP1), redeemG);
        assertEq(ledger.circulatingSupply(GOLD, AP1), 450 * UG_PER_G);
    }

    function test_reject_sell_unlocks_escrow() public {
        _executeBuy(user, GOLD, AP1, 300 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 100 * UG_PER_G);
        _adminReject(rid, "no");
        (,,,,,, bool released) = escrow.getEscrowDetails(rid);
        assertTrue(released);
        assertEq(ledger.userHolding(user, GOLD, AP1), 300 * UG_PER_G);
    }

    function test_cancel_sell_unlocks_escrow() public {
        _executeBuy(user, GOLD, AP1, 300 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 100 * UG_PER_G);
        _cancelRequest(user, rid);
        (,,,,,, bool released) = escrow.getEscrowDetails(rid);
        assertTrue(released);
    }

    function test_expire_unlocks_escrow() public {
        _executeBuy(user, GOLD, AP1, 300 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 100 * UG_PER_G);
        vm.warp(block.timestamp + gov.requestExpiryDuration() + 1);
        trade.expireRequest(rid);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Expired));
    }

    function test_daily_buy_cap_enforced() public {
        gov.setDailyCapForAsset(GOLD, StoexTypes.RequestType.Buy, 150 * UG_PER_G);
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.CapBuy.selector);
        trade.createBuyRequestFor(user, GOLD, AP1, 100 * UG_PER_G, 100 * UG_PER_G * 100, bytes32(uint256(2)), bytes32(0));
    }

    function test_timelock_blocks_sell_until_expiry() public {
        _executeBuy(user, GOLD, AP1, 200 * UG_PER_G);
        timelock.setWalletTimelock(user, block.timestamp + 5 days);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.Timelocked.selector);
        trade.createSellRequestFor(user, GOLD, AP1, 50 * UG_PER_G);
    }

    function test_timelock_admin_override_restores_sell() public {
        _executeBuy(user, GOLD, AP1, 200 * UG_PER_G);
        timelock.setWalletTimelock(user, block.timestamp + 5 days);
        timelock.overrideTimelock(user, 999);
        uint256 rid = _sellRequest(user, GOLD, AP1, 50 * UG_PER_G);
        assertTrue(rid > 0);
    }

    function test_buy_auto_executes_in_create_without_admin_execute() public {
        uint256 amountUg = 40 * UG_PER_G;
        uint256 rid = _executeBuy(user, GOLD, AP1, amountUg);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Executed));
        assertEq(ledger.userHolding(user, GOLD, AP1), amountUg);
    }

    function test_execute_request_reverts_for_buy_automation_path() public {
        uint256 rid = _executeBuy(user, GOLD, AP1, 5 * UG_PER_G);
        vm.expectRevert(TradeManager.BuyUsesAutoExecution.selector);
        trade.executeRequest(rid, bytes32(uint256(1)));
    }

    function test_execute_requires_settlement_ref() public {
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 10 * UG_PER_G);
        vm.expectRevert(TradeManager.ZeroSettlementRef.selector);
        trade.executeRequest(rid, bytes32(0));
    }

    function test_minimum_buy_ug_enforced() public {
        gov.setMinimumBuyValueInUg(GOLD, 60_000_000);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.BelowMinBuy.selector);
        trade.createBuyRequestFor(user, GOLD, AP1, 50_000_000, 50_000_000 * 100, bytes32(uint256(1)), bytes32(0));
    }

    function test_governance_admin_updates_min_redeem() public {
        gov.setMinRedeemAmountUg(5 * UG_PER_G);
        assertEq(gov.minRedeemAmountUg(), 5 * UG_PER_G);
    }

    function test_verify_kyc_for_rejects_non_relayer() public {
        address u = makeAddr("kycRelayer");
        _registerPendingKycUser(u);
        vm.prank(u);
        vm.expectRevert(StoexRelayerGate.NotTrustedForwarder.selector);
        registry.verifyKYCFor(u);
    }

    function test_verify_kyc_for_user_after_third_party_kyc() public {
        address u = makeAddr("kycUser");
        _registerPendingKycUser(u);
        assertTrue(registry.isEligibleForNonKycUser(u));
        vm.prank(forwarder);
        registry.verifyKYCFor(u);
        assertTrue(registry.isEligible(u));
        assertFalse(registry.isEligibleForNonKycUser(u));
    }

    function test_self_register_grants_user_role() public {
        address u = makeAddr("selfReg");
        vm.prank(forwarder);
        registry.registerUserFor(u, keccak256("self"), "kyc-ref");
        assertTrue(registry.hasRole(StoexRoles.USER_ROLE, u));
        assertTrue(trade.hasRole(StoexRoles.USER_ROLE, u));
        assertTrue(registry.isEligibleForNonKycUser(u));
    }

    function test_whitelist_not_eligible_until_kyc_verified() public {
        address u = makeAddr("fresh");
        vm.prank(forwarder);
        registry.registerUserFor(u, keccak256("x"), "r");
        assertFalse(registry.isEligible(u));
        assertTrue(registry.isEligibleForNonKycUser(u));
        vm.prank(forwarder);
        registry.verifyKYCFor(u);
        assertTrue(registry.isEligible(u));
        assertFalse(registry.isEligibleForNonKycUser(u));
    }

    function test_non_kyc_buy_before_verification() public {
        address u = makeAddr("pendingBuy");
        _registerPendingKycUser(u);
        gov.setNonKycMaxBuyFiatAmount(2_000_000);
        uint256 amountUg = 100 * UG_PER_G;
        vm.prank(forwarder);
        trade.createBuyRequestFor(u, GOLD, AP1, amountUg, 500_000, bytes32(uint256(42)), bytes32(0));
        assertEq(ledger.userHolding(u, GOLD, AP1), amountUg);
        assertTrue(ledger.tokenIdByBeneficiary(u, GOLD) != 0);
    }

    function test_non_kyc_buy_cannot_exceed_fiat_cap() public {
        address u = makeAddr("capPending");
        _registerPendingKycUser(u);
        gov.setNonKycMaxBuyFiatAmount(200_000);
        vm.prank(forwarder);
        trade.createBuyRequestFor(u, GOLD, AP1, 100 * UG_PER_G, 100_000, bytes32(uint256(1)), bytes32(0));
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.CapBuyNonKyc.selector);
        trade.createBuyRequestFor(u, GOLD, AP1, 100 * UG_PER_G, 120_000, bytes32(uint256(2)), bytes32(0));
    }

    function test_pending_user_cannot_sell() public {
        address u = makeAddr("noSell");
        _registerPendingKycUser(u);
        gov.setNonKycMaxBuyFiatAmount(5_000_000);
        vm.prank(forwarder);
        trade.createBuyRequestFor(u, GOLD, AP1, 200 * UG_PER_G, 1_000_000, bytes32(uint256(1)), bytes32(0));
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.NotEligible.selector);
        trade.createSellRequestFor(u, GOLD, AP1, 50 * UG_PER_G);
    }

    function test_whitelist_wallet_change_admin_only() public {
        address newW = makeAddr("newWallet");
        vm.prank(user);
        registry.requestWalletChange(user, newW);
        uint256 chId = registry.nextWalletChangeId();
        registry.approveWalletChange(chId);
        assertTrue(registry.isEligible(newW));
        assertFalse(registry.isEligible(user));
        assertTrue(registry.hasRole(StoexRoles.USER_ROLE, newW));
        assertFalse(registry.hasRole(StoexRoles.USER_ROLE, user));
        assertTrue(trade.hasRole(StoexRoles.USER_ROLE, newW));
        assertFalse(trade.hasRole(StoexRoles.USER_ROLE, user));
        assertEq(registry.walletOfUserId(registry.getProfile(newW).userId), newW);
    }

    function test_duplicate_userId_reverts() public {
        address u2 = makeAddr("dupId");
        vm.prank(forwarder);
        vm.expectRevert(WhitelistRegistry.UserIdAlreadyUsed.selector);
        registry.registerUserFor(u2, keccak256("user"), "r");
    }

    function test_non_kyc_cap_is_per_userId_not_wallet() public {
        // Same human cannot register a second wallet under a new userId for a fresh cap —
        // uniqueness is enforced; cap is keyed by userId once registered.
        address u = makeAddr("capUserId");
        bytes32 uid = keccak256("cap-uid");
        vm.prank(forwarder);
        registry.registerUserFor(u, uid, "r");
        gov.setNonKycMaxBuyFiatAmount(200_000);
        vm.prank(forwarder);
        trade.createBuyRequestFor(u, GOLD, AP1, 100 * UG_PER_G, 100_000, bytes32(uint256(1)), bytes32(0));
        assertEq(trade.nonKycFiatPurchasedByUserId(uid), 100_000);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.CapBuyNonKyc.selector);
        trade.createBuyRequestFor(u, GOLD, AP1, 100 * UG_PER_G, 120_000, bytes32(uint256(2)), bytes32(0));
        trade.adminResetNonKycFiatPurchased(uid);
        assertEq(trade.nonKycFiatPurchasedByUserId(uid), 0);
        vm.prank(forwarder);
        trade.createBuyRequestFor(u, GOLD, AP1, 100 * UG_PER_G, 120_000, bytes32(uint256(3)), bytes32(0));
    }

    function test_lot_timelock_blocks_sell_without_scanning_all_lots() public {
        _executeBuy(user, GOLD, AP1, 200 * UG_PER_G);
        uint256 lotId = 1;
        timelock.setLotTimelock(user, GOLD, lotId, block.timestamp + 5 days);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.Timelocked.selector);
        trade.createSellRequestFor(user, GOLD, AP1, 50 * UG_PER_G);
        timelock.overrideLotTimelock(user, GOLD, lotId, 1);
        uint256 rid = _sellRequest(user, GOLD, AP1, 50 * UG_PER_G);
        assertTrue(rid > 0);
    }

    function test_asset_precision_bounds() public {
        vm.expectRevert(GovernanceConfig.InvalidPrecision.selector);
        gov.setAssetPrecision(GOLD, 0);
        vm.expectRevert(GovernanceConfig.InvalidPrecision.selector);
        gov.setAssetPrecision(GOLD, 19);
        gov.setAssetPrecision(GOLD, 8);
        assertEq(gov.assetPrecision(GOLD), 8);
    }

    function test_certificate_soulbound_transfer_reverts_for_user() public {
        _executeBuy(user, GOLD, AP1, 10 * UG_PER_G);
        uint256 tid = ledger.tokenIdByBeneficiary(user, GOLD);
        vm.prank(user);
        vm.expectRevert(AssetLedger.Soulbound.selector);
        ledger.transferFrom(user, ap, tid);
    }

    function test_nominee_transfer_changes_custody_only() public {
        _executeBuy(user, GOLD, AP1, 10 * UG_PER_G);
        address nominee = makeAddr("nominee");
        _registerVerifiedUser(nominee);
        uint256 tid = ledger.tokenIdByBeneficiary(user, GOLD);
        ledger.nomineeTransferForAsset(GOLD, user, nominee);
        assertEq(ledger.ownerOf(tid), nominee);
        assertEq(ledger.beneficiaryOfToken(tid), user);
        assertEq(ledger.userHolding(user, GOLD, AP1), 10 * UG_PER_G);
    }

    function test_pause_blocks_subsequent_buy() public {
        uint256 first = 10 * UG_PER_G;
        _executeBuy(user, GOLD, AP1, first);
        ledger.pause();
        vm.prank(forwarder);
        vm.expectRevert();
        trade.createBuyRequestFor(user, GOLD, AP1, 10 * UG_PER_G, 10 * UG_PER_G * 100, bytes32(uint256(3)), bytes32(0));
    }

    function test_escrow_reduces_available_while_locked() public {
        _executeBuy(user, GOLD, AP1, 200 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 120 * UG_PER_G);
        assertEq(escrow.getAvailableBalance(user, GOLD, AP1), 80 * UG_PER_G);
        assertEq(escrow.getLockedAmount(user, GOLD, AP1), 120 * UG_PER_G);
        rid;
    }

    function test_getRequest_after_buy() public {
        uint256 rid = _executeBuy(user, GOLD, AP1, 10 * UG_PER_G);
        assertEq(trade.getRequest(rid).amountUg, 10 * UG_PER_G);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Executed));
    }

    function test_admin_can_mint_certificate_directly() public {
        address fresh = makeAddr("freshCert");
        registry.adminRegisterUser(keccak256("c"), fresh, "k");
        vm.prank(forwarder);
        registry.verifyKYCFor(fresh);
        ledger.mintCertificate(GOLD, fresh);
        assertTrue(ledger.tokenIdByBeneficiary(fresh, GOLD) != 0);
    }

    function test_user_buys_gold_and_silver_from_different_providers() public {
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        _executeBuy(user, SILVER, AP2, 50 * UG_PER_G);
        assertEq(ledger.userHolding(user, GOLD, AP1), 100 * UG_PER_G);
        assertEq(ledger.userHolding(user, SILVER, AP2), 50 * UG_PER_G);
        assertEq(ledger.userActiveProvider(user, GOLD), AP1);
        assertEq(ledger.userActiveProvider(user, SILVER), AP2);
        assertEq(ledger.totalCirculating(GOLD), 100 * UG_PER_G);
        assertEq(ledger.totalCirculating(SILVER), 50 * UG_PER_G);
    }

    function test_cannot_buy_same_asset_from_second_provider_while_holding() public {
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.ProviderBindingConflict.selector);
        trade.createBuyRequestFor(user, GOLD, AP2, 50 * UG_PER_G, 50 * UG_PER_G * 100, bytes32(uint256(1)), bytes32(0));
    }

    function test_can_switch_gold_provider_after_selling_all() public {
        providerReg.setProviderAsset(AP2, GOLD, true);
        providerReg.setAssetRouting(AP2, GOLD, payoutAp2, redeemAp2);
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 100 * UG_PER_G);
        _adminExecute(rid, bytes32(uint256(1)));
        assertEq(ledger.userActiveProvider(user, GOLD), bytes32(0));
        _executeBuy(user, GOLD, AP2, 50 * UG_PER_G);
        assertEq(ledger.userHolding(user, GOLD, AP2), 50 * UG_PER_G);
        assertEq(ledger.userActiveProvider(user, GOLD), AP2);
        assertEq(ledger.lifetimeIssued(GOLD, AP1), 100 * UG_PER_G);
        assertEq(ledger.lifetimeSoldBack(GOLD, AP1), 100 * UG_PER_G);
        assertEq(ledger.lifetimeIssued(GOLD, AP2), 50 * UG_PER_G);
    }

    function test_sell_rejects_wrong_provider() public {
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.ProviderBindingConflict.selector);
        trade.createSellRequestFor(user, GOLD, AP2, 50 * UG_PER_G);
    }

    function test_update_provider_name() public {
        (bool activeBefore,) = providerReg.getProvider(AP1);
        assertTrue(activeBefore);

        vm.prank(admin);
        providerReg.updateProviderName(AP1, "MMTC");

        (bool activeAfter, string memory name) = providerReg.getProvider(AP1);
        assertTrue(activeAfter);
        assertEq(name, "MMTC");
    }

    function test_circulating_invariant_after_buy_sell_redeem() public {
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        uint256 sellRid = _sellRequest(user, GOLD, AP1, 30 * UG_PER_G);
        _adminExecute(sellRid, bytes32(uint256(1)));
        uint256 redeemRid = _redeemRequest(user, GOLD, AP1, 20 * UG_PER_G);
        _adminExecute(redeemRid, bytes32(uint256(2)));

        assertEq(ledger.lifetimeIssued(GOLD, AP1), 100 * UG_PER_G);
        assertEq(ledger.lifetimeSoldBack(GOLD, AP1), 30 * UG_PER_G);
        assertEq(ledger.lifetimeRedeemed(GOLD, AP1), 20 * UG_PER_G);
        assertEq(
            ledger.circulatingSupply(GOLD, AP1),
            ledger.lifetimeIssued(GOLD, AP1) - ledger.lifetimeSoldBack(GOLD, AP1) - ledger.lifetimeRedeemed(GOLD, AP1)
        );
        assertEq(ledger.userHolding(user, GOLD, AP1), 50 * UG_PER_G);
    }
}
