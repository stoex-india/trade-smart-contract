// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexFixture} from "./helpers/StoexFixture.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {AssetLedger} from "../src/AssetLedger.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {StoexRelayerGate} from "../src/base/StoexRelayerGate.sol";

/// @title StoexPRD
/// @notice Integration tests mapped to Technical PRD v2.0 flows and public functions.
contract StoexPRDTest is StoexFixture {
    uint256 internal constant UG_PER_G = 1_000_000;

    function test_buy_flow_mints_and_credits_micrograms() public {
        uint256 mg = 100 * UG_PER_G;
        _executeBuy(user, GOLD, AP1, mg);
        assertEq(ledger.userHolding(user, GOLD, AP1), mg);
        assertTrue(ledger.tokenIdByBeneficiary(user, GOLD) != 0);
    }

    function test_sell_flow_escrow_release_and_decrease() public {
        _executeBuy(user, GOLD, AP1, 500 * UG_PER_G);
        uint256 sellG = 200 * UG_PER_G;
        uint256 rid = _sellRequest(user, GOLD, AP1, sellG, bytes32(uint256(1)));
        _approveRequest(ap, rid);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        assertEq(ledger.userHolding(user, GOLD, AP1), 300 * UG_PER_G);
        assertEq(escrow.getLockedAmount(user, GOLD, AP1), 0);
    }

    function test_redeem_flow_four_party_approval() public {
        _executeBuy(user, GOLD, AP1, 500 * UG_PER_G);
        uint256 redeemG = 50 * UG_PER_G;
        uint256 rid = _redeemRequest(user, GOLD, AP1, redeemG, bytes32(uint256(2)));
        _approveRequest(ap, rid);
        _approveRequest(vp, rid);
        _approveRequest(pap, rid);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        assertEq(ledger.userHolding(user, GOLD, AP1), 450 * UG_PER_G);
    }

    function test_mint_flow_VP_then_AT() public {
        uint256 poolBefore = ledger.providerPoolBalance(GOLD, AP1);
        StoexTypes.MintLotMeta memory lot = StoexTypes.MintLotMeta({
            assetId: GOLD,
            providerId: AP1,
            vaultReceiptId: bytes32(uint256(7)),
            batchId: bytes32(uint256(8)),
            purity: 9999,
            depositTimestamp: block.timestamp,
            vpId: vp,
            lockUntilTs: 0,
            amountUg: 0
        });
        uint256 rid = _proposeMint(ap, GOLD, AP1, 80 * UG_PER_G, bytes32(uint256(9)), lot);
        _approveRequest(vp, rid);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        assertEq(ledger.userHolding(user, GOLD, AP1), 0);
        assertEq(ledger.providerPoolBalance(GOLD, AP1), poolBefore + 80 * UG_PER_G);
    }

    function test_burn_flow_debits_ap_pool() public {
        uint256 poolBefore = ledger.providerPoolBalance(GOLD, AP1);
        uint256 supplyBefore = ledger.totalSupply(GOLD);
        uint256 rid = _proposeBurn(ap, GOLD, AP1, 100 * UG_PER_G, bytes32(uint256(3)), "adjustment");
        _approveRequest(vp, rid);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        assertEq(ledger.providerPoolBalance(GOLD, AP1), poolBefore - 100 * UG_PER_G);
        assertEq(ledger.totalSupply(GOLD), supplyBefore - 100 * UG_PER_G);
    }

    function test_reject_sell_unlocks_escrow() public {
        _executeBuy(user, GOLD, AP1, 300 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 100 * UG_PER_G, bytes32(uint256(4)));
        _rejectRequest(ap, rid, "no");
        (,,,,,, bool released) = escrow.getEscrowDetails(rid);
        assertTrue(released);
    }

    function test_cancel_sell_unlocks_escrow() public {
        _executeBuy(user, GOLD, AP1, 300 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 100 * UG_PER_G, bytes32(uint256(5)));
        _cancelRequest(user, rid);
        (,,,,,, bool released) = escrow.getEscrowDetails(rid);
        assertTrue(released);
    }

    function test_expire_unlocks_escrow() public {
        _executeBuy(user, GOLD, AP1, 300 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 100 * UG_PER_G, bytes32(uint256(6)));
        vm.warp(block.timestamp + gov.requestExpiryDuration() + 1);
        trade.expireRequest(rid);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Expired));
    }

    function test_daily_buy_cap_enforced() public {
        vm.prank(at);
        gov.setDailyCapForAsset(GOLD, StoexTypes.RequestType.Buy, 150 * UG_PER_G);
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.CapBuy.selector);
        trade.createBuyRequestFor(user, GOLD, AP1, 100 * UG_PER_G, 100 * UG_PER_G * 100, bytes32(uint256(2)), bytes32(0));
    }

    function test_timelock_blocks_sell_until_expiry() public {
        _executeBuy(user, GOLD, AP1, 200 * UG_PER_G);
        vm.prank(ap);
        timelock.setWalletTimelock(user, block.timestamp + 5 days);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.Timelocked.selector);
        trade.createSellRequestFor(user, GOLD, AP1, 50 * UG_PER_G, bytes32(uint256(1)));
    }

    function test_timelock_trustee_override_restores_sell() public {
        _executeBuy(user, GOLD, AP1, 200 * UG_PER_G);
        vm.prank(ap);
        timelock.setWalletTimelock(user, block.timestamp + 5 days);
        vm.prank(at);
        timelock.overrideTimelock(user, 999);
        uint256 rid = _sellRequest(user, GOLD, AP1, 50 * UG_PER_G, bytes32(uint256(1)));
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
        trade.executeRequest(rid);
    }

    function test_minimum_buy_ug_enforced() public {
        gov.setMinimumBuyValueInUg(GOLD, 60_000_000);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.BelowMinBuy.selector);
        trade.createBuyRequestFor(user, GOLD, AP1, 50_000_000, 50_000_000 * 100, bytes32(uint256(1)), bytes32(0));
    }

    function test_governance_AT_updates_min_redeem() public {
        vm.prank(at);
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
        vm.prank(at);
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
        vm.prank(at);
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
        vm.prank(at);
        gov.setNonKycMaxBuyFiatAmount(5_000_000);
        vm.prank(forwarder);
        trade.createBuyRequestFor(u, GOLD, AP1, 200 * UG_PER_G, 1_000_000, bytes32(uint256(1)), bytes32(0));
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.NotEligible.selector);
        trade.createSellRequestFor(u, GOLD, AP1, 50 * UG_PER_G, bytes32(uint256(3)));
    }

    function test_mint_flow_without_vp_when_disabled() public {
        gov.setVpRequiredForApprovals(false);
        StoexTypes.MintLotMeta memory lot = StoexTypes.MintLotMeta({
            assetId: GOLD,
            providerId: AP1,
            vaultReceiptId: bytes32(uint256(7)),
            batchId: bytes32(uint256(8)),
            purity: 9999,
            depositTimestamp: block.timestamp,
            vpId: vp,
            lockUntilTs: 0,
            amountUg: 0
        });
        uint256 rid = _proposeMint(ap, GOLD, AP1, 80 * UG_PER_G, bytes32(uint256(9)), lot);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        assertEq(ledger.userHolding(user, GOLD, AP1), 0);
        assertEq(ledger.providerPoolBalance(GOLD, AP1), 10_000_000_000 + 80 * UG_PER_G);
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
        uint256 rid = _sellRequest(user, GOLD, AP1, 120 * UG_PER_G, bytes32(uint256(1)));
        assertEq(escrow.getAvailableBalance(user, GOLD, AP1), 80 * UG_PER_G);
        assertEq(escrow.getLockedAmount(user, GOLD, AP1), 120 * UG_PER_G);
        rid;
    }

    function test_mint_applies_default_lot_timelock_when_configured() public {
        vm.prank(at);
        gov.setDefaultTimelockDuration(3 days);
        StoexTypes.MintLotMeta memory lot;
        lot.assetId = GOLD;
        lot.providerId = AP1;
        uint256 rid = _proposeMint(ap, GOLD, AP1, 30 * UG_PER_G, bytes32(uint256(1)), lot);
        _approveRequest(vp, rid);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        uint256[] memory lots = ledger.getPoolLotIds(GOLD, AP1);
        uint256 exp = timelock.getLotTimelockExpiry(lots[lots.length - 1]);
        assertGt(exp, block.timestamp);
    }

    function test_getRequest_after_buy() public {
        uint256 rid = _executeBuy(user, GOLD, AP1, 10 * UG_PER_G);
        assertEq(trade.getRequest(rid).amountUg, 10 * UG_PER_G);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Executed));
    }

    function test_AP_can_mint_certificate_directly() public {
        address fresh = makeAddr("freshCert");
        registry.adminRegisterUser(keccak256("c"), fresh, "k");
        vm.prank(forwarder);
        registry.verifyKYCFor(fresh);
        vm.prank(ap);
        ledger.mintCertificate(GOLD, fresh);
        assertTrue(ledger.tokenIdByBeneficiary(fresh, GOLD) != 0);
    }

    function test_timelock_applyMintLotTimelock_from_trade_only() public {
        vm.prank(ap);
        vm.expectRevert(TimelockController.NotTradeManager.selector);
        timelock.applyMintLotTimelock(1, block.timestamp + 1);
    }

    function test_user_buys_gold_and_silver_from_different_providers() public {
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        _executeBuy(user, SILVER, AP2, 50 * UG_PER_G);
        assertEq(ledger.userHolding(user, GOLD, AP1), 100 * UG_PER_G);
        assertEq(ledger.userHolding(user, SILVER, AP2), 50 * UG_PER_G);
        assertEq(ledger.userActiveProvider(user, GOLD), AP1);
        assertEq(ledger.userActiveProvider(user, SILVER), AP2);
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
        _mintPoolInventory(GOLD, AP2, ap2, 1_000_000_000);
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 100 * UG_PER_G, bytes32(uint256(1)));
        _approveRequest(ap, rid);
        _approveRequest(at, rid);
        trade.executeRequest(rid);
        assertEq(ledger.userActiveProvider(user, GOLD), bytes32(0));
        _executeBuy(user, GOLD, AP2, 50 * UG_PER_G);
        assertEq(ledger.userHolding(user, GOLD, AP2), 50 * UG_PER_G);
        assertEq(ledger.userActiveProvider(user, GOLD), AP2);
    }

    function test_sell_rejects_wrong_provider() public {
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.ProviderBindingConflict.selector);
        trade.createSellRequestFor(user, GOLD, AP2, 50 * UG_PER_G, bytes32(uint256(1)));
    }

    function test_ap_approval_requires_provider_operator() public {
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 50 * UG_PER_G, bytes32(uint256(1)));
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.NotProviderOperator.selector);
        trade.approveRequestFor(ap2, rid);
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
}
