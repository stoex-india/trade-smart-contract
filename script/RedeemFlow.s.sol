// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";

/// @title RedeemFlow
/// @notice PRD redeem flow: USER create -> AP approve -> VP approve -> PAP approve -> AT approve -> ADMIN execute.
contract RedeemFlow is Script {
    function run() external {
        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));

        uint256 adminPk = vm.envOr("ADMIN_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
        uint256 userPk = vm.envUint("USER_PRIVATE_KEY");
        uint256 apPk = vm.envOr("AP_PRIVATE_KEY", adminPk);
        uint256 vpPk = vm.envOr("VP_PRIVATE_KEY", adminPk);
        uint256 papPk = vm.envOr("PAP_PRIVATE_KEY", adminPk);
        uint256 atPk = vm.envOr("AT_PRIVATE_KEY", adminPk);

        uint256 grams = vm.envOr("REDEEM_GRAMS", uint256(1000));
        bytes32 deliveryRef = vm.envOr("REDEEM_DELIVERY_REF", bytes32("REDEEM-REF-001"));

        vm.startBroadcast(userPk);
        uint256 requestId = trade.createRedeemRequest(grams, deliveryRef);
        vm.stopBroadcast();

        vm.startBroadcast(apPk);
        trade.approveRequest(requestId);
        vm.stopBroadcast();

        vm.startBroadcast(vpPk);
        trade.approveRequest(requestId);
        vm.stopBroadcast();

        vm.startBroadcast(papPk);
        trade.approveRequest(requestId);
        vm.stopBroadcast();

        vm.startBroadcast(atPk);
        trade.approveRequest(requestId);
        vm.stopBroadcast();

        vm.startBroadcast(adminPk);
        trade.executeRequest(requestId);
        vm.stopBroadcast();

        console2.log("Redeem request executed:", requestId);
        console2.log("Final status:", uint256(trade.getRequestStatus(requestId)));
        require(trade.getRequestStatus(requestId) == StoexTypes.RequestStatus.Executed, "redeem not executed");
    }
}
