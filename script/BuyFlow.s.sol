// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";

/// @title BuyFlow
/// @notice PRD buy flow: USER create -> AP approve -> AT approve -> ADMIN execute.
contract BuyFlow is Script {
    bytes32 private constant _DEFAULT_PAYMENT_REF = 0x4255592d5245462d303031000000000000000000000000000000000000000000;

    function run() external {
        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));

        uint256 adminPk = vm.envOr("ADMIN_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
        uint256 userPk = vm.envUint("USER_PRIVATE_KEY");
        uint256 apPk = vm.envOr("AP_PRIVATE_KEY", adminPk);
        uint256 atPk = vm.envOr("AT_PRIVATE_KEY", adminPk);

        uint256 grams = vm.envOr("BUY_GRAMS", uint256(1000));
        bytes32 paymentRef = vm.envOr("BUY_PAYMENT_REF", _DEFAULT_PAYMENT_REF);

        vm.startBroadcast(userPk);
        uint256 requestId = trade.createBuyRequest(grams, paymentRef);
        vm.stopBroadcast();

        vm.startBroadcast(apPk);
        trade.approveRequest(requestId);
        vm.stopBroadcast();

        vm.startBroadcast(atPk);
        trade.approveRequest(requestId);
        vm.stopBroadcast();

        vm.startBroadcast(adminPk);
        trade.executeRequest(requestId);
        vm.stopBroadcast();

        console2.log("Buy request executed:", requestId);
        console2.log("Final status:", uint256(trade.getRequestStatus(requestId)));
        require(trade.getRequestStatus(requestId) == StoexTypes.RequestStatus.Executed, "buy not executed");
    }
}
