// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";
import {RelayerScript} from "./helpers/RelayerScript.sol";

/// @title BurnFlow
contract BurnFlow is RelayerScript {
    bytes32 private constant _DEFAULT_BURN_REF = 0x4255524e2d5245462d3030310000000000000000000000000000000000000000;

    function run() external {
        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));

        uint256 adminPk = vm.envOr("ADMIN_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
        uint256 apPk = vm.envOr("AP_PRIVATE_KEY", adminPk);
        uint256 vpPk = vm.envOr("VP_PRIVATE_KEY", adminPk);
        uint256 atPk = vm.envOr("AT_PRIVATE_KEY", adminPk);
        uint256 relayerPk = _relayerPk();

        address apAddr = vm.addr(apPk);
        address vpAddr = vm.addr(vpPk);
        address atAddr = vm.addr(atPk);

        bytes32 assetId = _envLabelBytes32("ASSET_LABEL", "GOLD");
        bytes32 providerId = _envLabelBytes32("PROVIDER_LABEL", "AP1");
        uint256 amountUg = vm.envOr("BURN_AMOUNT_UG", uint256(500_000));
        bytes32 referenceId = vm.envOr("BURN_REF_ID", _DEFAULT_BURN_REF);
        string memory reason = vm.envOr("BURN_REASON", string("Ops burn"));

        vm.startBroadcast(relayerPk);
        uint256 requestId = trade.proposeBurnFor(apAddr, assetId, providerId, amountUg, referenceId, reason);
        trade.approveRequestFor(vpAddr, requestId);
        trade.approveRequestFor(atAddr, requestId);
        vm.stopBroadcast();

        vm.startBroadcast(adminPk);
        trade.executeRequest(requestId);
        vm.stopBroadcast();

        console2.log("Burn request executed:", requestId);
        console2.log("Final status:", uint256(trade.getRequestStatus(requestId)));
        require(trade.getRequestStatus(requestId) == StoexTypes.RequestStatus.Executed, "burn not executed");
    }
}
