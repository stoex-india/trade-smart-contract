// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";

/// @title BuyFlow
/// @notice Buy flow: single tx — investor `createBuyRequest` credits mg from AP pool (no admin execute).
contract BuyFlow is Script {
    bytes32 private constant _DEFAULT_PAYMENT_REF = 0x4255592d5245462d303031000000000000000000000000000000000000000000;

    function run() external {
        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));

        uint256 userPk = vm.envUint("USER_PRIVATE_KEY");

        uint256 weightUg = vm.envOr("BUY_WEIGHT_UG", uint256(1_000_000)); // default 1 g
        bytes32 paymentRef = vm.envOr("BUY_PAYMENT_REF", _DEFAULT_PAYMENT_REF);
        uint256 fiatValue = vm.envOr("BUY_FIAT_VALUE", uint256(1));
        bytes32 txDetailsHash = vm.envOr("BUY_TX_DETAILS_HASH", bytes32(0));

        vm.startBroadcast(userPk);
        uint256 requestId = trade.createBuyRequest(weightUg, fiatValue, paymentRef, txDetailsHash);
        vm.stopBroadcast();

        console2.log("Buy request completed:", requestId);
        console2.log("Final status:", uint256(trade.getRequestStatus(requestId)));
        require(trade.getRequestStatus(requestId) == StoexTypes.RequestStatus.Executed, "buy not executed");
    }
}
