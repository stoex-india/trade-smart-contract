// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexFixture} from "./helpers/StoexFixture.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";
import {StoexOpsGuard} from "../src/base/StoexOpsGuard.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {TradeManagerLib} from "../src/libraries/TradeManagerLib.sol";

contract AdminReconcileTest is StoexFixture {
    uint256 internal constant UG_PER_G = 1_000_000;

    event RequestCreated(
        uint256 indexed requestId,
        bytes32 indexed assetId,
        bytes32 indexed providerId,
        StoexTypes.RequestType requestType,
        address initiator,
        uint256 amountUg,
        uint256 fiatValue
    );
    event RequestExecuted(uint256 indexed requestId, StoexTypes.RequestType requestType);
    event AdminTradeReconciled(
        uint256 indexed requestId, address indexed user, address indexed operator, StoexTypes.RequestType requestType
    );

    address internal ops;
    address internal pendingUser;

    function setUp() public override {
        super.setUp();
        ops = makeAddr("ops");
        pendingUser = makeAddr("pendingUser");
        gov.grantRole(StoexRoles.OPS_ADMIN_ROLE, ops);
        _registerPendingKycUser(pendingUser);
    }

    function test_admin_buy_credits_user_and_records_operator() public {
        uint256 amt = 100 * UG_PER_G;
        uint256 expectedId = trade.nextRequestId() + 1;
        vm.expectEmit(true, true, true, true, address(trade));
        emit RequestCreated(expectedId, GOLD, AP1, StoexTypes.RequestType.Buy, user, amt, _defaultFiat(amt));
        vm.expectEmit(true, true, false, true, address(trade));
        emit RequestExecuted(expectedId, StoexTypes.RequestType.Buy);
        vm.expectEmit(true, true, true, true, address(trade));
        emit AdminTradeReconciled(expectedId, user, admin, StoexTypes.RequestType.Buy);
        uint256 rid = trade.adminCreateBuyRequest(
            user, GOLD, AP1, amt, _defaultFiat(amt), bytes32(uint256(1)), bytes32(uint256(2))
        );
        assertEq(rid, expectedId);
        assertEq(ledger.userHolding(user, GOLD, AP1), amt);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Executed));
        assertEq(trade.getRequest(rid).initiator, user);
        assertEq(trade.getRequest(rid).targetUser, user);
    }

    function test_admin_sell_stays_proposed_then_executeRequest() public {
        _executeBuy(user, GOLD, AP1, 200 * UG_PER_G);
        uint256 rid = trade.adminCreateSellRequest(user, GOLD, AP1, 50 * UG_PER_G);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Proposed));
        assertEq(trade.getRequest(rid).initiator, user);
        assertEq(escrow.getLockedAmount(user, GOLD, AP1), 50 * UG_PER_G);
        trade.executeRequest(rid, bytes32(uint256(0xabc)));
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Executed));
        assertEq(ledger.userHolding(user, GOLD, AP1), 150 * UG_PER_G);
    }

    function test_admin_redeem_stays_proposed_then_executeRequest() public {
        _executeBuy(user, GOLD, AP1, 30 * UG_PER_G);
        uint256 rid = trade.adminCreateRedeemRequest(user, GOLD, AP1, 10 * UG_PER_G);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Proposed));
        trade.executeRequest(rid, bytes32(uint256(0xdef)));
        assertEq(ledger.userHolding(user, GOLD, AP1), 20 * UG_PER_G);
        assertEq(ledger.lifetimeRedeemed(GOLD, AP1), 10 * UG_PER_G);
    }

    function test_ops_allowed_when_capability_on() public {
        uint256 amt = 10 * UG_PER_G;
        vm.prank(ops);
        uint256 rid =
            trade.adminCreateBuyRequest(user, GOLD, AP1, amt, _defaultFiat(amt), bytes32(uint256(1)), bytes32(0));
        assertEq(ledger.userHolding(user, GOLD, AP1), amt);
        assertEq(trade.getRequest(rid).initiator, user);
    }

    function test_ops_rejected_when_capability_off() public {
        gov.setOpsCapability(StoexRoles.OPS_RECONCILE_TRADE, false);
        vm.prank(ops);
        vm.expectRevert(StoexOpsGuard.NotAuthorized.selector);
        trade.adminCreateBuyRequest(user, GOLD, AP1, 10 * UG_PER_G, 1_000_000, bytes32(uint256(1)), bytes32(0));
        uint256 rid =
            trade.adminCreateBuyRequest(user, GOLD, AP1, 10 * UG_PER_G, 1_000_000, bytes32(uint256(1)), bytes32(0));
        assertGt(rid, 0);
    }

    function test_user_and_forwarder_rejected() public {
        vm.prank(user);
        vm.expectRevert(StoexOpsGuard.NotAuthorized.selector);
        trade.adminCreateBuyRequest(user, GOLD, AP1, 10 * UG_PER_G, 1_000_000, bytes32(uint256(1)), bytes32(0));
        vm.prank(forwarder);
        vm.expectRevert(StoexOpsGuard.NotAuthorized.selector);
        trade.adminCreateBuyRequest(user, GOLD, AP1, 10 * UG_PER_G, 1_000_000, bytes32(uint256(1)), bytes32(0));
    }

    function test_timelock_still_reverts_admin_sell() public {
        _executeBuy(user, GOLD, AP1, 20 * UG_PER_G);
        timelock.setWalletTimelock(user, block.timestamp + 1 days);
        vm.expectRevert(TradeManagerLib.Timelocked.selector);
        trade.adminCreateSellRequest(user, GOLD, AP1, 5 * UG_PER_G);
    }

    function test_buy_cap_still_reverts_admin_buy() public {
        gov.setDailyCapForAsset(GOLD, StoexTypes.RequestType.Buy, 150 * UG_PER_G);
        trade.adminCreateBuyRequest(
            user, GOLD, AP1, 100 * UG_PER_G, _defaultFiat(100 * UG_PER_G), bytes32(uint256(1)), bytes32(0)
        );
        vm.expectRevert(TradeManager.CapBuy.selector);
        trade.adminCreateBuyRequest(
            user, GOLD, AP1, 60 * UG_PER_G, _defaultFiat(60 * UG_PER_G), bytes32(uint256(2)), bytes32(0)
        );
    }

    function test_admin_verify_kyc_then_sell_works() public {
        gov.setNonKycMaxBuyFiatAmount(5_000_000);
        vm.prank(forwarder);
        trade.createBuyRequestFor(pendingUser, GOLD, AP1, 20 * UG_PER_G, 1_000_000, bytes32(uint256(1)), bytes32(0));
        registry.adminVerifyKYC(pendingUser);
        uint256 rid = trade.adminCreateSellRequest(pendingUser, GOLD, AP1, 5 * UG_PER_G);
        assertEq(uint256(trade.getRequestStatus(rid)), uint256(StoexTypes.RequestStatus.Proposed));
    }

    function test_pending_kyc_sell_still_reverts() public {
        gov.setNonKycMaxBuyFiatAmount(5_000_000);
        vm.prank(forwarder);
        trade.createBuyRequestFor(
            pendingUser, GOLD, AP1, 20 * UG_PER_G, 1_000_000, bytes32(uint256(1)), bytes32(0)
        );
        vm.expectRevert(TradeManager.NotEligible.selector);
        trade.adminCreateSellRequest(pendingUser, GOLD, AP1, 5 * UG_PER_G);
    }

    function test_batch_two_buys_returns_both_ids() public {
        TradeManager.BuyReconcile[] memory items = new TradeManager.BuyReconcile[](2);
        items[0] = TradeManager.BuyReconcile({
            user: user,
            assetId: GOLD,
            providerId: AP1,
            weightUg: 10 * UG_PER_G,
            fiatValue: _defaultFiat(10 * UG_PER_G),
            paymentRef: bytes32(uint256(1)),
            txDetailsHash: bytes32(0)
        });
        items[1] = TradeManager.BuyReconcile({
            user: user,
            assetId: GOLD,
            providerId: AP1,
            weightUg: 15 * UG_PER_G,
            fiatValue: _defaultFiat(15 * UG_PER_G),
            paymentRef: bytes32(uint256(2)),
            txDetailsHash: bytes32(0)
        });
        uint256[] memory ids = trade.adminCreateBuyRequestBatch(items);
        assertEq(ids.length, 2);
        assertEq(ids[0] + 1, ids[1]);
        assertEq(ledger.userHolding(user, GOLD, AP1), 25 * UG_PER_G);
        assertEq(uint256(trade.getRequestStatus(ids[0])), uint256(StoexTypes.RequestStatus.Executed));
        assertEq(uint256(trade.getRequestStatus(ids[1])), uint256(StoexTypes.RequestStatus.Executed));
    }

    function test_batch_two_sells_returns_both_ids() public {
        _executeBuy(user, GOLD, AP1, 80 * UG_PER_G);
        TradeManager.SellReconcile[] memory items = new TradeManager.SellReconcile[](2);
        items[0] = TradeManager.SellReconcile({user: user, assetId: GOLD, providerId: AP1, amountUg: 10 * UG_PER_G});
        items[1] = TradeManager.SellReconcile({user: user, assetId: GOLD, providerId: AP1, amountUg: 20 * UG_PER_G});
        uint256[] memory ids = trade.adminCreateSellRequestBatch(items);
        assertEq(ids.length, 2);
        assertEq(uint256(trade.getRequestStatus(ids[0])), uint256(StoexTypes.RequestStatus.Proposed));
        assertEq(uint256(trade.getRequestStatus(ids[1])), uint256(StoexTypes.RequestStatus.Proposed));
        assertEq(escrow.getLockedAmount(user, GOLD, AP1), 30 * UG_PER_G);
    }

    function test_batch_two_redeems_returns_both_ids() public {
        _executeBuy(user, GOLD, AP1, 30 * UG_PER_G);
        TradeManager.RedeemReconcile[] memory items = new TradeManager.RedeemReconcile[](2);
        items[0] = TradeManager.RedeemReconcile({user: user, assetId: GOLD, providerId: AP1, amountUg: 10 * UG_PER_G});
        items[1] = TradeManager.RedeemReconcile({user: user, assetId: GOLD, providerId: AP1, amountUg: 10 * UG_PER_G});
        uint256[] memory ids = trade.adminCreateRedeemRequestBatch(items);
        assertEq(ids.length, 2);
        assertEq(uint256(trade.getRequestStatus(ids[0])), uint256(StoexTypes.RequestStatus.Proposed));
        assertEq(uint256(trade.getRequestStatus(ids[1])), uint256(StoexTypes.RequestStatus.Proposed));
    }

    function test_empty_batch_reverts() public {
        TradeManager.BuyReconcile[] memory buys = new TradeManager.BuyReconcile[](0);
        vm.expectRevert(TradeManager.EmptyBatch.selector);
        trade.adminCreateBuyRequestBatch(buys);
        TradeManager.SellReconcile[] memory sells = new TradeManager.SellReconcile[](0);
        vm.expectRevert(TradeManager.EmptyBatch.selector);
        trade.adminCreateSellRequestBatch(sells);
        TradeManager.RedeemReconcile[] memory redeems = new TradeManager.RedeemReconcile[](0);
        vm.expectRevert(TradeManager.EmptyBatch.selector);
        trade.adminCreateRedeemRequestBatch(redeems);
    }

    function test_batch_second_item_failure_reverts_first() public {
        gov.setDailyCapForAsset(GOLD, StoexTypes.RequestType.Buy, 150 * UG_PER_G);
        TradeManager.BuyReconcile[] memory items = new TradeManager.BuyReconcile[](2);
        items[0] = TradeManager.BuyReconcile({
            user: user,
            assetId: GOLD,
            providerId: AP1,
            weightUg: 100 * UG_PER_G,
            fiatValue: _defaultFiat(100 * UG_PER_G),
            paymentRef: bytes32(uint256(1)),
            txDetailsHash: bytes32(0)
        });
        items[1] = TradeManager.BuyReconcile({
            user: user,
            assetId: GOLD,
            providerId: AP1,
            weightUg: 60 * UG_PER_G,
            fiatValue: _defaultFiat(60 * UG_PER_G),
            paymentRef: bytes32(uint256(2)),
            txDetailsHash: bytes32(0)
        });
        vm.expectRevert(TradeManager.CapBuy.selector);
        trade.adminCreateBuyRequestBatch(items);
        assertEq(ledger.userHolding(user, GOLD, AP1), 0);
        assertEq(trade.nextRequestId(), 0);
    }
}
