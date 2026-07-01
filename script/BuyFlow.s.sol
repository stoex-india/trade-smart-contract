// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {RelayerScript} from "./helpers/RelayerScript.sol";

/// @title BuyFlow
contract BuyFlow is RelayerScript {
    bytes32 private constant _DEFAULT_PAYMENT_REF = 0x4255592d5245462d303031000000000000000000000000000000000000000000;

    function run() external {
        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));

        address user = vm.envAddress("BUY_USER");
        uint256 relayerPk = _relayerPk();

        bytes32 assetId = _envLabelBytes32("ASSET_LABEL", "GOLD");
        bytes32 providerId = _envLabelBytes32("PROVIDER_LABEL", "AP1");
        uint256 weightUg = vm.envOr("BUY_WEIGHT_UG", uint256(1_000_000));
        bytes32 paymentRef = vm.envOr("BUY_PAYMENT_REF", _DEFAULT_PAYMENT_REF);
        uint256 fiatValue = vm.envOr("BUY_FIAT_VALUE", uint256(1));
        bytes32 txDetailsHash = vm.envOr("BUY_TX_DETAILS_HASH", bytes32(0));

        vm.startBroadcast(relayerPk);
        uint256 requestId =
            trade.createBuyRequestFor(user, assetId, providerId, weightUg, fiatValue, paymentRef, txDetailsHash);
        vm.stopBroadcast();

        console2.log("Buy request completed:", requestId);
        console2.log("Final status:", uint256(trade.getRequestStatus(requestId)));
        require(trade.getRequestStatus(requestId) == StoexTypes.RequestStatus.Executed, "buy not executed");
    }
}
