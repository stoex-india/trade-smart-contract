// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {RelayerScript} from "./helpers/RelayerScript.sol";

/// @title RedeemFlow
/// @notice V1: user creates redeem (relayer) → admin executes with settlement ref.
contract RedeemFlow is RelayerScript {
    bytes32 private constant _DEFAULT_SETTLEMENT_REF = 0x52454445454d2d5245462d303031000000000000000000000000000000000000;

    function run() external {
        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));

        uint256 adminPk = vm.envOr("ADMIN_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
        uint256 relayerPk = _relayerPk();

        address user = vm.envAddress("REDEEM_USER");
        bytes32 assetId = _envLabelBytes32("ASSET_LABEL", "GOLD");
        bytes32 providerId = _envLabelBytes32("PROVIDER_LABEL", "AP1");
        uint256 amountUg = vm.envOr("REDEEM_AMOUNT_UG", uint256(1_000_000));
        bytes32 settlementRef = vm.envOr("REDEEM_SETTLEMENT_REF", _DEFAULT_SETTLEMENT_REF);

        vm.startBroadcast(relayerPk);
        uint256 requestId = trade.createRedeemRequestFor(user, assetId, providerId, amountUg);
        vm.stopBroadcast();

        vm.startBroadcast(adminPk);
        trade.executeRequest(requestId, settlementRef);
        vm.stopBroadcast();

        console2.log("Redeem request executed:", requestId);
        console2.log("Final status:", uint256(trade.getRequestStatus(requestId)));
        require(trade.getRequestStatus(requestId) == StoexTypes.RequestStatus.Executed, "redeem not executed");
    }
}
