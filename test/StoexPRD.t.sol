// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexFixture} from "./helpers/StoexFixture.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {GoldNFT} from "../src/GoldNFT.sol";
import {TimelockController} from "../src/TimelockController.sol";

/// @title StoexPRD
/// @notice Integration tests mapped to Technical PRD v2.0 flows and public functions.
contract StoexPRDTest is StoexFixture {
    /// @dev Micrograms per gram — on-chain gold integers are **µg** (`1 g = 1_000_000 µg`).
    uint256 internal constant UG_PER_G = 1_000_000;

    function test_buy_flow_mints_and_credits_micrograms() public {
        uint256 mg = 100 * UG_PER_G;
        _executeBuy(user, mg);
        assertEq(gold.userHolding(user), mg);
        assertTrue(gold.tokenIdByBeneficiary(user) != 0);
    }

    function test_sell_flow_escrow_release_and_decrease() public {
        _executeBuy(user, 500 * UG_PER_G);
        uint256 sellG = 200 * UG_PER_G;
        uint256 rid = _sellRequest(user, sellG, bytes32(uint256(1)));
        _approveRequest(ap, rid);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        assertEq(gold.userHolding(user), 300 * UG_PER_G);
        assertEq(escrow.getLockedAmount(user), 0);
    }

    function test_redeem_flow_four_party_approval() public {
        _executeBuy(user, 500 * UG_PER_G);
        uint256 redeemG = 50 * UG_PER_G;
        uint256 rid = _redeemRequest(user, redeemG, bytes32(uint256(2)));
        _approveRequest(ap, rid);
        _approveRequest(vp, rid);
        _approveRequest(pap, rid);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        assertEq(gold.userHolding(user), 450 * UG_PER_G);
    }

    function test_mint_flow_VP_then_AT() public {
        uint256 poolBefore = gold.totalAssetProviderBalance();
        StoexTypes.MintLotMeta memory lot = StoexTypes.MintLotMeta({
            vaultReceiptId: bytes32(uint256(7)),
            batchId: bytes32(uint256(8)),
            purity: 9999,
            depositTimestamp: block.timestamp,
            apId: ap,
            vpId: vp,
            lockUntilTs: 0,
            amountUg: 0
        });
        uint256 rid = _proposeMint(ap, 80 * UG_PER_G, bytes32(uint256(9)), lot);
        _approveRequest(vp, rid);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        assertEq(gold.userHolding(user), 0);
        assertEq(gold.totalAssetProviderBalance(), poolBefore + 80 * UG_PER_G);
        assertEq(gold.totalGoldSupply(), poolBefore + 80 * UG_PER_G + gold.circulatingSupply());
    }

    function test_burn_flow_debits_ap_pool() public {
        uint256 poolBefore = gold.totalAssetProviderBalance();
        uint256 supplyBefore = gold.totalGoldSupply();
        uint256 rid = _proposeBurn(ap, 100 * UG_PER_G, bytes32(uint256(3)), "adjustment");
        _approveRequest(vp, rid);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        assertEq(gold.totalAssetProviderBalance(), poolBefore - 100 * UG_PER_G);
        assertEq(gold.totalGoldSupply(), supplyBefore - 100 * UG_PER_G);
    }

    function test_reject_sell_unlocks_escrow() public {
        _executeBuy(user, 300 * UG_PER_G);
        uint256 rid = _sellRequest(user, 100 * UG_PER_G, bytes32(uint256(4)));
        _rejectRequest(ap, rid, "no");
        (,,,, bool released) = escrow.getEscrowDetails(rid);
        assertTrue(released);
    }

    function test_cancel_sell_unlocks_escrow() public {
        _executeBuy(user, 300 * UG_PER_G);
        uint256 rid = _sellRequest(user, 100 * UG_PER_G, bytes32(uint256(5)));
        _cancelRequest(user, rid);
        (,,,, bool released) = escrow.getEscrowDetails(rid);
        assertTrue(released);
    }

    function test_expire_unlocks_escrow() public {
        _executeBuy(user, 300 * UG_PER_G);
        uint256 rid = _sellRequest(user, 100 * UG_PER_G, bytes32(uint256(6)));
        vm.warp(block.timestamp + gov.requestExpiryDuration() + 1);
        trade.expireRequest(rid);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Expired));
    }

    function test_daily_buy_cap_enforced() public {
        vm.prank(at);
        gov.setDailyCap(StoexTypes.RequestType.Buy, 150 * UG_PER_G);
        _executeBuy(user, 100 * UG_PER_G);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.CapBuy.selector);
        trade.createBuyRequestFor(user, 100 * UG_PER_G, 100 * UG_PER_G * 100, bytes32(uint256(2)), bytes32(0));
    }

    function test_timelock_blocks_sell_until_expiry() public {
        _executeBuy(user, 200 * UG_PER_G);
        vm.prank(ap);
        timelock.setWalletTimelock(user, block.timestamp + 5 days);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.Timelocked.selector);
        trade.createSellRequestFor(user, 50 * UG_PER_G, bytes32(uint256(1)));
    }

    function test_timelock_trustee_override_restores_sell() public {
        _executeBuy(user, 200 * UG_PER_G);
        vm.prank(ap);
        timelock.setWalletTimelock(user, block.timestamp + 5 days);
        vm.prank(at);
        timelock.overrideTimelock(user, 999);
        uint256 rid = _sellRequest(user, 50 * UG_PER_G, bytes32(uint256(1)));
        assertTrue(rid > 0);
    }

    function test_buy_auto_executes_in_create_without_admin_execute() public {
        uint256 amountUg = 40 * UG_PER_G;
        uint256 rid = _executeBuy(user, amountUg);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Executed));
        assertEq(gold.userHolding(user), amountUg);
    }

    function test_execute_request_reverts_for_buy_automation_path() public {
        uint256 rid = _executeBuy(user, 5 * UG_PER_G);
        vm.expectRevert(TradeManager.BuyUsesAutoExecution.selector);
        trade.executeRequest(rid);
    }

    function test_minimum_buy_ug_enforced() public {
        gov.setMinimumBuyGoldValueInUg(60_000_000); // 60 g
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.BelowMinBuyGold.selector);
        trade.createBuyRequestFor(user, 50_000_000, 50_000_000 * 100, bytes32(uint256(1)), bytes32(0)); // 50 g
    }

    function test_governance_AT_updates_min_redeem() public {
        vm.prank(at);
        gov.setMinRedeemAmountUg(5 * UG_PER_G);
        assertEq(gov.minRedeemAmountUg(), 5 * UG_PER_G);
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
        registry.verifyKYC(u);
        assertTrue(registry.isEligible(u));
        assertFalse(registry.isEligibleForNonKycUser(u));
    }

    function test_non_kyc_buy_before_verification() public {
        address u = makeAddr("pendingBuy");
        _registerPendingKycUser(u);
        vm.prank(at);
        gov.setNonKycMaxBuyFiatAmount(2_000_000);
        uint256 amountUg = 100 * UG_PER_G;
        vm.prank(forwarder);
        trade.createBuyRequestFor(u, amountUg, 500_000, bytes32(uint256(42)), bytes32(0));
        assertEq(gold.userHolding(u), amountUg);
        assertTrue(gold.tokenIdByBeneficiary(u) != 0);
    }

    function test_non_kyc_buy_cannot_exceed_fiat_cap() public {
        address u = makeAddr("capPending");
        _registerPendingKycUser(u);
        vm.prank(at);
        gov.setNonKycMaxBuyFiatAmount(200_000);
        vm.prank(forwarder);
        trade.createBuyRequestFor(u, 100 * UG_PER_G, 100_000, bytes32(uint256(1)), bytes32(0));
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.CapBuyNonKyc.selector);
        trade.createBuyRequestFor(u, 100 * UG_PER_G, 120_000, bytes32(uint256(2)), bytes32(0));
    }

    function test_pending_user_cannot_sell() public {
        address u = makeAddr("noSell");
        _registerPendingKycUser(u);
        vm.prank(at);
        gov.setNonKycMaxBuyFiatAmount(5_000_000);
        vm.prank(forwarder);
        trade.createBuyRequestFor(u, 200 * UG_PER_G, 1_000_000, bytes32(uint256(1)), bytes32(0));
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.NotEligible.selector);
        trade.createSellRequestFor(u, 50 * UG_PER_G, bytes32(uint256(3)));
    }

    function test_mint_flow_without_vp_when_disabled() public {
        gov.setVpRequiredForApprovals(false);
        StoexTypes.MintLotMeta memory lot = StoexTypes.MintLotMeta({
            vaultReceiptId: bytes32(uint256(7)),
            batchId: bytes32(uint256(8)),
            purity: 9999,
            depositTimestamp: block.timestamp,
            apId: ap,
            vpId: vp,
            lockUntilTs: 0,
            amountUg: 0
        });
        uint256 rid = _proposeMint(ap, 80 * UG_PER_G, bytes32(uint256(9)), lot);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        assertEq(gold.userHolding(user), 0);
        assertEq(gold.totalAssetProviderBalance(), 10_000_000_000 + 80 * UG_PER_G);
    }

    function test_whitelist_wallet_change_after_dual_approval() public {
        address newW = makeAddr("newWallet");
        vm.prank(user);
        registry.requestWalletChange(user, newW);
        uint256 chId = registry.nextWalletChangeId();
        registry.approveWalletChange(chId);
        vm.prank(at);
        registry.approveWalletChange(chId);
        assertTrue(registry.isEligible(newW));
        assertFalse(registry.isEligible(user));
    }

    function test_gold_soulbound_transfer_reverts_for_user() public {
        _executeBuy(user, 10 * UG_PER_G);
        uint256 tid = gold.tokenIdByBeneficiary(user);
        vm.prank(user);
        vm.expectRevert(GoldNFT.Soulbound.selector);
        gold.transferFrom(user, ap, tid);
    }

    function test_gold_nominee_transfer_changes_custody_only() public {
        _executeBuy(user, 10 * UG_PER_G);
        address nominee = makeAddr("nominee");
        _registerVerifiedUser(nominee);
        uint256 tid = gold.tokenIdByBeneficiary(user);
        gold.nomineeTransfer(user, nominee);
        assertEq(gold.ownerOf(tid), nominee);
        assertEq(gold.beneficiaryOfToken(tid), user);
        assertEq(gold.userHolding(user), 10 * UG_PER_G);
    }

    function test_gold_pause_blocks_subsequent_buy() public {
        uint256 first = 10 * UG_PER_G;
        _executeBuy(user, first);
        gold.pause();
        vm.prank(forwarder);
        vm.expectRevert();
        trade.createBuyRequestFor(user, 10 * UG_PER_G, 10 * UG_PER_G * 100, bytes32(uint256(3)), bytes32(0));
    }

    function test_escrow_reduces_available_while_locked() public {
        _executeBuy(user, 200 * UG_PER_G);
        uint256 rid = _sellRequest(user, 120 * UG_PER_G, bytes32(uint256(1)));
        assertEq(escrow.getAvailableBalance(user), 80 * UG_PER_G);
        assertEq(escrow.getLockedAmount(user), 120 * UG_PER_G);
        rid;
    }

    function test_mint_applies_default_lot_timelock_when_configured() public {
        vm.prank(at);
        gov.setDefaultTimelockDuration(3 days);
        StoexTypes.MintLotMeta memory lot;
        uint256 rid = _proposeMint(ap, 30 * UG_PER_G, bytes32(uint256(1)), lot);
        _approveRequest(vp, rid);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        uint256[] memory lots = gold.getPoolLotIds();
        uint256 exp = timelock.getLotTimelockExpiry(lots[lots.length - 1]);
        assertGt(exp, block.timestamp);
    }

    function test_getRequest_after_buy() public {
        uint256 rid = _executeBuy(user, 10 * UG_PER_G);
        assertEq(trade.getRequest(rid).amountUg, 10 * UG_PER_G);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Executed));
    }

    function test_AP_can_mint_certificate_directly() public {
        address fresh = makeAddr("freshCert");
        registry.adminRegisterUser(keccak256("c"), fresh, "k");
        registry.verifyKYC(fresh);
        vm.prank(ap);
        gold.mintCertificate(fresh);
        assertTrue(gold.tokenIdByBeneficiary(fresh) != 0);
    }

    function test_timelock_applyMintLotTimelock_from_trade_only() public {
        vm.prank(ap);
        vm.expectRevert(TimelockController.NotTradeManager.selector);
        timelock.applyMintLotTimelock(1, block.timestamp + 1);
    }
}
