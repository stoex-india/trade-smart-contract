// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {RelayerScript} from "./helpers/RelayerScript.sol";

/// @title RedeemFlow
contract RedeemFlow is RelayerScript {
    bytes32 private constant _DEFAULT_DELIVERY_REF = 0x52454445454d2d5245462d303031000000000000000000000000000000000000;

    function run() external {
        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));

        uint256 adminPk = vm.envOr("ADMIN_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
        uint256 apPk = vm.envOr("AP_PRIVATE_KEY", adminPk);
        uint256 vpPk = vm.envOr("VP_PRIVATE_KEY", adminPk);
        uint256 papPk = vm.envOr("PAP_PRIVATE_KEY", adminPk);
        uint256 atPk = vm.envOr("AT_PRIVATE_KEY", adminPk);
        uint256 relayerPk = _relayerPk();

        address user = vm.envAddress("REDEEM_USER");
        address apAddr = vm.addr(apPk);
        address vpAddr = vm.addr(vpPk);
        address papAddr = vm.addr(papPk);
        address atAddr = vm.addr(atPk);

        bytes32 assetId = _envLabelBytes32("ASSET_LABEL", "GOLD");
        bytes32 providerId = _envLabelBytes32("PROVIDER_LABEL", "AP1");
        uint256 amountUg = vm.envOr("REDEEM_AMOUNT_UG", uint256(1_000_000));
        bytes32 deliveryRef = vm.envOr("REDEEM_DELIVERY_REF", _DEFAULT_DELIVERY_REF);

        vm.startBroadcast(relayerPk);
        uint256 requestId = trade.createRedeemRequestFor(user, assetId, providerId, amountUg, deliveryRef);
        trade.approveRequestFor(apAddr, requestId);
        trade.approveRequestFor(vpAddr, requestId);
        trade.approveRequestFor(papAddr, requestId);
        trade.approveRequestFor(atAddr, requestId);
        vm.stopBroadcast();

        vm.startBroadcast(adminPk);
        trade.executeRequest(requestId);
        vm.stopBroadcast();

        console2.log("Redeem request executed:", requestId);
        console2.log("Final status:", uint256(trade.getRequestStatus(requestId)));
        require(trade.getRequestStatus(requestId) == StoexTypes.RequestStatus.Executed, "redeem not executed");
    }
}
