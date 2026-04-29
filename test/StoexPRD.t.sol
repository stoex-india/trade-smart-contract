// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexFixture} from "./helpers/StoexFixture.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {GoldNFT} from "../src/GoldNFT.sol";
import {TimelockController} from "../src/TimelockController.sol";

/// @title StoexPRD
/// @notice Integration tests mapped to Technical PRD v2.0 flows and public functions.
contract StoexPRDTest is StoexFixture {
    uint256 internal constant G = 1e3;

    function test_buy_flow_mints_and_credits_grams() public {
        uint256 grams = 100 * G;
        _executeBuy(user, grams);
        assertEq(gold.userHolding(user), grams);
        assertTrue(gold.tokenIdByBeneficiary(user) != 0);
    }

    function test_sell_flow_escrow_release_and_decrease() public {
        _executeBuy(user, 500 * G);
        uint256 sellG = 200 * G;
        vm.prank(user);
        uint256 rid = trade.createSellRequest(sellG, bytes32(uint256(1)));
        vm.prank(ap);
        trade.approveRequest(rid);
        vm.prank(at);
        trade.approveRequest(rid);
        trade.executeRequest(rid);
        assertEq(gold.userHolding(user), 300 * G);
        assertEq(escrow.getLockedAmount(user), 0);
    }

    function test_redeem_flow_four_party_approval() public {
        _executeBuy(user, 500 * G);
        uint256 redeemG = 50 * G;
        vm.prank(user);
        uint256 rid = trade.createRedeemRequest(redeemG, bytes32(uint256(2)));
        vm.prank(ap);
        trade.approveRequest(rid);
        vm.prank(vp);
        trade.approveRequest(rid);
        vm.prank(pap);
        trade.approveRequest(rid);
        vm.prank(at);
        trade.approveRequest(rid);
        trade.executeRequest(rid);
        assertEq(gold.userHolding(user), 450 * G);
    }

    function test_mint_flow_VP_then_AT() public {
        StoexTypes.MintLotMeta memory lot = StoexTypes.MintLotMeta({
            vaultReceiptId: bytes32(uint256(7)),
            batchId: bytes32(uint256(8)),
            purity: 9999,
            depositTimestamp: block.timestamp,
            apId: ap,
            vpId: vp,
            lockUntilTs: 0,
            grams: 0
        });
        vm.prank(ap);
        uint256 rid = trade.proposeMint(80 * G, user, bytes32(uint256(9)), lot);
        vm.prank(vp);
        trade.approveRequest(rid);
        vm.prank(at);
        trade.approveRequest(rid);
        trade.executeRequest(rid);
        assertEq(gold.userHolding(user), 80 * G);
    }

    function test_burn_flow_debits_vault_bookkeeping() public {
        _executeBuy(vaultBk, 1000 * G);
        vm.prank(ap);
        uint256 rid = trade.proposeBurn(100 * G, bytes32(uint256(3)), "adjustment");
        vm.prank(vp);
        trade.approveRequest(rid);
        vm.prank(at);
        trade.approveRequest(rid);
        trade.executeRequest(rid);
        assertEq(gold.userHolding(vaultBk), 900 * G);
    }

    function test_reject_sell_unlocks_escrow() public {
        _executeBuy(user, 300 * G);
        vm.prank(user);
        uint256 rid = trade.createSellRequest(100 * G, bytes32(uint256(4)));
        vm.prank(ap);
        trade.rejectRequest(rid, "no");
        (,,,, bool released) = escrow.getEscrowDetails(rid);
        assertTrue(released);
    }

    function test_cancel_sell_unlocks_escrow() public {
        _executeBuy(user, 300 * G);
        vm.prank(user);
        uint256 rid = trade.createSellRequest(100 * G, bytes32(uint256(5)));
        vm.prank(user);
        trade.cancelRequest(rid);
        (,,,, bool released) = escrow.getEscrowDetails(rid);
        assertTrue(released);
    }

    function test_expire_unlocks_escrow() public {
        _executeBuy(user, 300 * G);
        vm.prank(user);
        uint256 rid = trade.createSellRequest(100 * G, bytes32(uint256(6)));
        vm.warp(block.timestamp + gov.requestExpiryDuration() + 1);
        trade.expireRequest(rid);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Expired));
    }

    function test_daily_buy_cap_enforced() public {
        vm.prank(at);
        gov.setDailyCap(StoexTypes.RequestType.Buy, 150 * G);
        _executeBuy(user, 100 * G);
        vm.prank(user);
        vm.expectRevert(TradeManager.CapBuy.selector);
        trade.createBuyRequest(100 * G, bytes32(uint256(2)));
    }

    function test_timelock_blocks_sell_until_expiry() public {
        _executeBuy(user, 200 * G);
        vm.prank(ap);
        timelock.setWalletTimelock(user, block.timestamp + 5 days);
        vm.prank(user);
        vm.expectRevert(TradeManager.Timelocked.selector);
        trade.createSellRequest(50 * G, bytes32(uint256(1)));
    }

    function test_timelock_trustee_override_restores_sell() public {
        _executeBuy(user, 200 * G);
        vm.prank(ap);
        timelock.setWalletTimelock(user, block.timestamp + 5 days);
        vm.prank(at);
        timelock.overrideTimelock(user, 999);
        vm.prank(user);
        uint256 rid = trade.createSellRequest(50 * G, bytes32(uint256(1)));
        assertTrue(rid > 0);
    }

    function test_co_signatures_execute_buy_in_one_tx() public {
        uint256 grams = 40 * G;
        vm.prank(user);
        uint256 rid = trade.createBuyRequest(grams, bytes32(uint256(99)));
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = trade.hashCoSignBatch(rid, 0, deadline);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _packSig(apKey, digest);
        sigs[1] = _packSig(atKey, digest);
        trade.executeWithCoSignatures(rid, 0, deadline, sigs);
        assertEq(gold.userHolding(user), grams);
    }

    function test_governance_AT_updates_min_redeem() public {
        vm.prank(at);
        gov.setMinRedeemQuantity(5 * G);
        assertEq(gov.minRedeemQuantity(), 5 * G);
    }

    function test_whitelist_not_eligible_until_kyc_verified() public {
        address u = makeAddr("fresh");
        registry.registerUser(keccak256("x"), u, "r");
        assertFalse(registry.isEligible(u));
        assertTrue(registry.isEligibleForRestrictedBuy(u));
        registry.verifyKYC(u);
        assertTrue(registry.isEligible(u));
        assertFalse(registry.isEligibleForRestrictedBuy(u));
    }

    function test_restricted_buy_before_kyc() public {
        address u = makeAddr("pendingBuy");
        _registerPendingKycUser(u);
        vm.prank(at);
        gov.setNonKycMaxHoldingCap(2_000 * G);
        uint256 grams = 100 * G;
        vm.prank(u);
        uint256 rid = trade.createBuyRequest(grams, bytes32(uint256(42)));
        vm.prank(ap);
        trade.approveRequest(rid);
        vm.prank(at);
        trade.approveRequest(rid);
        trade.executeRequest(rid);
        assertEq(gold.userHolding(u), grams);
        assertTrue(gold.tokenIdByBeneficiary(u) != 0);
    }

    function test_restricted_buy_cannot_exceed_non_kyc_holding_cap() public {
        address u = makeAddr("capPending");
        _registerPendingKycUser(u);
        vm.prank(at);
        gov.setNonKycMaxHoldingCap(150 * G);
        vm.prank(u);
        uint256 rid1 = trade.createBuyRequest(100 * G, bytes32(uint256(1)));
        vm.prank(ap);
        trade.approveRequest(rid1);
        vm.prank(at);
        trade.approveRequest(rid1);
        trade.executeRequest(rid1);
        vm.prank(u);
        vm.expectRevert(TradeManager.CapBuyNonKyc.selector);
        trade.createBuyRequest(100 * G, bytes32(uint256(2)));
    }

    function test_pending_user_cannot_sell() public {
        address u = makeAddr("noSell");
        _registerPendingKycUser(u);
        vm.prank(at);
        gov.setNonKycMaxHoldingCap(5_000 * G);
        vm.prank(u);
        uint256 rid = trade.createBuyRequest(200 * G, bytes32(uint256(1)));
        vm.prank(ap);
        trade.approveRequest(rid);
        vm.prank(at);
        trade.approveRequest(rid);
        trade.executeRequest(rid);
        vm.prank(u);
        vm.expectRevert(TradeManager.NotEligible.selector);
        trade.createSellRequest(50 * G, bytes32(uint256(3)));
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
            grams: 0
        });
        vm.prank(ap);
        uint256 rid = trade.proposeMint(80 * G, user, bytes32(uint256(9)), lot);
        vm.prank(at);
        trade.approveRequest(rid);
        trade.executeRequest(rid);
        assertEq(gold.userHolding(user), 80 * G);
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
        _executeBuy(user, 10 * G);
        uint256 tid = gold.tokenIdByBeneficiary(user);
        vm.prank(user);
        vm.expectRevert(GoldNFT.Soulbound.selector);
        gold.transferFrom(user, ap, tid);
    }

    function test_gold_nominee_transfer_changes_custody_only() public {
        _executeBuy(user, 10 * G);
        address nominee = makeAddr("nominee");
        _registerVerifiedUser(nominee);
        uint256 tid = gold.tokenIdByBeneficiary(user);
        gold.nomineeTransfer(user, nominee);
        assertEq(gold.ownerOf(tid), nominee);
        assertEq(gold.beneficiaryOfToken(tid), user);
        assertEq(gold.userHolding(user), 10 * G);
    }

    function test_gold_pause_blocks_trade_execution() public {
        uint256 grams = 10 * G;
        vm.prank(user);
        uint256 rid = trade.createBuyRequest(grams, bytes32(uint256(1)));
        vm.prank(ap);
        trade.approveRequest(rid);
        vm.prank(at);
        trade.approveRequest(rid);
        gold.pause();
        vm.expectRevert();
        trade.executeRequest(rid);
    }

    function test_escrow_reduces_available_while_locked() public {
        _executeBuy(user, 200 * G);
        vm.prank(user);
        uint256 rid = trade.createSellRequest(120 * G, bytes32(uint256(1)));
        assertEq(escrow.getAvailableBalance(user), 80 * G);
        assertEq(escrow.getLockedAmount(user), 120 * G);
        rid;
    }

    function test_mint_applies_default_lot_timelock_when_configured() public {
        vm.prank(at);
        gov.setDefaultTimelockDuration(3 days);
        StoexTypes.MintLotMeta memory lot;
        vm.prank(ap);
        uint256 rid = trade.proposeMint(30 * G, user, bytes32(uint256(1)), lot);
        vm.prank(vp);
        trade.approveRequest(rid);
        vm.prank(at);
        trade.approveRequest(rid);
        trade.executeRequest(rid);
        uint256[] memory lots = gold.getUserLotIds(user);
        uint256 exp = timelock.getLotTimelockExpiry(lots[lots.length - 1]);
        assertGt(exp, block.timestamp);
    }

    function test_getUserRequests_returns_rows() public {
        vm.prank(user);
        trade.createBuyRequest(10 * G, bytes32(uint256(1)));
        (uint256[] memory ids,) = trade.getUserRequests(user, 0, 10);
        assertEq(ids.length, 1);
        assertEq(trade.getRequest(ids[0]).grams, 10 * G);
    }

    function test_AP_can_mint_certificate_directly() public {
        address fresh = makeAddr("freshCert");
        registry.registerUser(keccak256("c"), fresh, "k");
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
