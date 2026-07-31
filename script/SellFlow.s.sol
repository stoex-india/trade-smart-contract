// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {RelayerScript} from "./helpers/RelayerScript.sol";

/// @title SellFlow
/// @notice V1: user creates sell (relayer) → admin executes with settlement ref.
contract SellFlow is RelayerScript {
    bytes32 private constant _DEFAULT_SETTLEMENT_REF = 0x53454c4c2d5245462d3030310000000000000000000000000000000000000000;

    function run() external {
        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));

        uint256 adminPk = vm.envOr("ADMIN_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
        uint256 relayerPk = _relayerPk();

        address user = vm.envAddress("SELL_USER");
        bytes32 assetId = _envLabelBytes32("ASSET_LABEL", "GOLD");
        bytes32 providerId = _envLabelBytes32("PROVIDER_LABEL", "AP1");
        uint256 amountUg = vm.envOr("SELL_AMOUNT_UG", uint256(500_000));
        bytes32 settlementRef = vm.envOr("SELL_SETTLEMENT_REF", _DEFAULT_SETTLEMENT_REF);

        vm.startBroadcast(relayerPk);
        uint256 requestId = trade.createSellRequestFor(user, assetId, providerId, amountUg);
        vm.stopBroadcast();

        vm.startBroadcast(adminPk);
        trade.executeRequest(requestId, settlementRef);
        vm.stopBroadcast();

        console2.log("Sell request executed:", requestId);
        console2.log("Final status:", uint256(trade.getRequestStatus(requestId)));
        require(trade.getRequestStatus(requestId) == StoexTypes.RequestStatus.Executed, "sell not executed");
    }
}
