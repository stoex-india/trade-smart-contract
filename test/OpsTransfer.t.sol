// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexFixture} from "./helpers/StoexFixture.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";
import {StoexOpsGuard} from "../src/base/StoexOpsGuard.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {AssetLedger} from "../src/AssetLedger.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {TradeManagerLib} from "../src/libraries/TradeManagerLib.sol";

contract OpsTransferTest is StoexFixture {
    uint256 internal constant UG_PER_G = 1_000_000;

    address internal ops;
    address internal dest;
    address internal pendingDest;

    function setUp() public override {
        super.setUp();
        ops = makeAddr("ops");
        dest = makeAddr("dest");
        pendingDest = makeAddr("pendingDest");
        gov.grantRole(StoexRoles.OPS_ADMIN_ROLE, ops);
        _registerVerifiedUser(dest);
        _registerPendingKycUser(pendingDest);
    }

    function test_ops_can_set_policy_when_cap_enabled() public {
        vm.prank(ops);
        gov.setMinimumBuyValueInUg(GOLD, 2_000);
        assertEq(gov.minimumBuyValueInUg(GOLD), 2_000);
    }

    function test_ops_policy_blocked_when_cap_disabled() public {
        gov.setOpsCapability(StoexRoles.OPS_SET_POLICY, false);
        vm.prank(ops);
        vm.expectRevert(StoexOpsGuard.NotAuthorized.selector);
        gov.setMinimumBuyValueInUg(GOLD, 2_000);
        gov.setMinimumBuyValueInUg(GOLD, 3_000);
        assertEq(gov.minimumBuyValueInUg(GOLD), 3_000);
    }

    function test_admin_verify_kyc_makes_user_eligible() public {
        assertFalse(registry.isEligible(pendingDest));
        registry.adminVerifyKYC(pendingDest);
        assertTrue(registry.isEligible(pendingDest));
        assertFalse(registry.isEligibleForNonKycUser(pendingDest));
    }

    function test_ops_verify_kyc_when_capability_on() public {
        vm.prank(ops);
        registry.adminVerifyKYC(pendingDest);
        assertTrue(registry.isEligible(pendingDest));
    }

    function test_ops_verify_kyc_rejected_when_capability_off() public {
        gov.setOpsCapability(StoexRoles.OPS_VERIFY_KYC, false);
        vm.prank(ops);
        vm.expectRevert(StoexOpsGuard.NotAuthorized.selector);
        registry.adminVerifyKYC(pendingDest);
        registry.adminVerifyKYC(pendingDest);
        assertTrue(registry.isEligible(pendingDest));
    }

    function test_user_and_forwarder_cannot_admin_verify_kyc() public {
        vm.prank(pendingDest);
        vm.expectRevert(StoexOpsGuard.NotAuthorized.selector);
        registry.adminVerifyKYC(pendingDest);
        vm.prank(forwarder);
        vm.expectRevert(StoexOpsGuard.NotAuthorized.selector);
        registry.adminVerifyKYC(pendingDest);
    }

    function test_admin_verify_kyc_twice_reverts() public {
        registry.adminVerifyKYC(pendingDest);
        vm.expectRevert(WhitelistRegistry.KycNotPending.selector);
        registry.adminVerifyKYC(pendingDest);
    }

    function test_ops_cannot_pause() public {
        vm.prank(ops);
        vm.expectRevert();
        trade.pause();
    }

    function test_ops_execute_sell() public {
        _executeBuy(user, GOLD, AP1, 200 * UG_PER_G);
        uint256 rid = _sellRequest(user, GOLD, AP1, 50 * UG_PER_G);
        vm.prank(ops);
        trade.executeRequest(rid, bytes32(uint256(0x11)));
        assertEq(ledger.userHolding(user, GOLD, AP1), 150 * UG_PER_G);
    }

    function test_user_transfer_mints_dest_nft_and_keeps_circulating() public {
        uint256 amt = 80 * UG_PER_G;
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        uint256 circ = ledger.circulatingSupply(GOLD, AP1);
        uint256 issued = ledger.lifetimeIssued(GOLD, AP1);
        assertEq(ledger.tokenIdByBeneficiary(dest, GOLD), 0);

        vm.prank(forwarder);
        uint256 rid = trade.transferAssetFor(user, dest, GOLD, AP1, amt, bytes32(uint256(7)));

        assertEq(ledger.userHolding(user, GOLD, AP1), 20 * UG_PER_G);
        assertEq(ledger.userHolding(dest, GOLD, AP1), amt);
        assertEq(ledger.circulatingSupply(GOLD, AP1), circ);
        assertEq(ledger.lifetimeIssued(GOLD, AP1), issued);
        assertTrue(ledger.tokenIdByBeneficiary(user, GOLD) != 0);
        assertTrue(ledger.tokenIdByBeneficiary(dest, GOLD) != 0);
        assertEq(uint256(trade.getRequest(rid).requestType), uint256(StoexTypes.RequestType.Transfer));
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Executed));
        assertEq(trade.getRequest(rid).paymentRefId, bytes32(uint256(7)));
    }

    function test_full_transfer_keeps_source_certificate() public {
        uint256 amt = 40 * UG_PER_G;
        _executeBuy(user, GOLD, AP1, amt);
        uint256 srcNft = ledger.tokenIdByBeneficiary(user, GOLD);
        vm.prank(forwarder);
        trade.transferAssetFor(user, dest, GOLD, AP1, amt, bytes32(0));
        assertEq(ledger.userHolding(user, GOLD, AP1), 0);
        assertEq(ledger.tokenIdByBeneficiary(user, GOLD), srcNft);
        assertEq(ledger.userActiveProvider(user, GOLD), bytes32(0));
        assertEq(ledger.userActiveProvider(dest, GOLD), AP1);
    }

    function test_admin_transfer_from_registered_source() public {
        _executeBuy(user, GOLD, AP1, 50 * UG_PER_G);
        uint256 rid = trade.transferAsset(user, dest, GOLD, AP1, 10 * UG_PER_G, bytes32(uint256(3)));
        assertEq(ledger.userHolding(dest, GOLD, AP1), 10 * UG_PER_G);
        assertEq(trade.getRequest(rid).initiator, admin);
    }

    function test_ops_transfer_when_cap_on() public {
        _executeBuy(user, GOLD, AP1, 50 * UG_PER_G);
        vm.prank(ops);
        trade.transferAsset(user, dest, GOLD, AP1, 5 * UG_PER_G, bytes32(0));
        assertEq(ledger.userHolding(dest, GOLD, AP1), 5 * UG_PER_G);
    }

    function test_self_transfer_reverts() public {
        _executeBuy(user, GOLD, AP1, 10 * UG_PER_G);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.SelfTransfer.selector);
        trade.transferAssetFor(user, user, GOLD, AP1, 1 * UG_PER_G, bytes32(0));
    }

    function test_unregistered_dest_reverts() public {
        address stranger = makeAddr("stranger");
        _executeBuy(user, GOLD, AP1, 10 * UG_PER_G);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.NotUser.selector);
        trade.transferAssetFor(user, stranger, GOLD, AP1, 1 * UG_PER_G, bytes32(0));
    }

    function test_dest_kyc_flag_blocks_pending() public {
        _executeBuy(user, GOLD, AP1, 20 * UG_PER_G);
        gov.setTransferDestKycRequired(true);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.NotEligible.selector);
        trade.transferAssetFor(user, pendingDest, GOLD, AP1, 1 * UG_PER_G, bytes32(0));
    }

    function test_dest_pending_ok_when_flag_off() public {
        _executeBuy(user, GOLD, AP1, 20 * UG_PER_G);
        vm.prank(forwarder);
        trade.transferAssetFor(user, pendingDest, GOLD, AP1, 2 * UG_PER_G, bytes32(0));
        assertEq(ledger.userHolding(pendingDest, GOLD, AP1), 2 * UG_PER_G);
        assertTrue(ledger.tokenIdByBeneficiary(pendingDest, GOLD) != 0);
    }

    function test_source_kyc_flag_blocks_pending_sender() public {
        vm.prank(forwarder);
        trade.createBuyRequestFor(pendingDest, GOLD, AP1, 5_000, 500_000, bytes32(uint256(1)), bytes32(uint256(2)));
        gov.setTransferSourceKycRequired(true);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.NotEligible.selector);
        trade.transferAssetFor(pendingDest, dest, GOLD, AP1, 1_000, bytes32(0));
    }

    function test_escrow_locked_not_transferable() public {
        _executeBuy(user, GOLD, AP1, 100 * UG_PER_G);
        _sellRequest(user, GOLD, AP1, 80 * UG_PER_G);
        vm.prank(forwarder);
        vm.expectRevert(TradeManager.InsufficientAvailable.selector);
        trade.transferAssetFor(user, dest, GOLD, AP1, 30 * UG_PER_G, bytes32(0));
        vm.prank(forwarder);
        trade.transferAssetFor(user, dest, GOLD, AP1, 20 * UG_PER_G, bytes32(0));
        assertEq(ledger.userHolding(dest, GOLD, AP1), 20 * UG_PER_G);
    }

    function test_timelocked_source_cannot_transfer() public {
        _executeBuy(user, GOLD, AP1, 10 * UG_PER_G);
        timelock.setWalletTimelock(user, block.timestamp + 1 days);
        vm.prank(forwarder);
        vm.expectRevert(TradeManagerLib.Timelocked.selector);
        trade.transferAssetFor(user, dest, GOLD, AP1, 1 * UG_PER_G, bytes32(0));
    }

    function test_provider_conflict_on_dest() public {
        _executeBuy(user, GOLD, AP1, 20 * UG_PER_G);
        _executeBuy(dest, GOLD, AP2, 10 * UG_PER_G);
        vm.prank(forwarder);
        vm.expectRevert(AssetLedger.ProviderBindingConflict.selector);
        trade.transferAssetFor(user, dest, GOLD, AP1, 5 * UG_PER_G, bytes32(0));
    }

    function test_silver_transfer() public {
        _executeBuy(user, SILVER, AP1, 15 * UG_PER_G);
        vm.prank(forwarder);
        trade.transferAssetFor(user, dest, SILVER, AP1, 5 * UG_PER_G, bytes32(0));
        assertEq(ledger.userHolding(dest, SILVER, AP1), 5 * UG_PER_G);
    }
}
