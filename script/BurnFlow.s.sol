// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";

/// @title BurnFlow
/// @notice PRD burn flow: AP propose -> VP approve -> AT approve -> ADMIN execute.
contract BurnFlow is Script {
    bytes32 private constant _DEFAULT_BURN_REF = 0x4255524e2d5245462d3030310000000000000000000000000000000000000000;

    function run() external {
        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));

        uint256 adminPk = vm.envOr("ADMIN_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
        uint256 apPk = vm.envOr("AP_PRIVATE_KEY", adminPk);
        uint256 vpPk = vm.envOr("VP_PRIVATE_KEY", adminPk);
        uint256 atPk = vm.envOr("AT_PRIVATE_KEY", adminPk);

        uint256 amountUg = vm.envOr("BURN_AMOUNT_UG", uint256(500_000));
        bytes32 referenceId = vm.envOr("BURN_REF_ID", _DEFAULT_BURN_REF);
        string memory reason = vm.envOr("BURN_REASON", string("Ops burn"));

        vm.startBroadcast(apPk);
        uint256 requestId = trade.proposeBurn(amountUg, referenceId, reason);
        vm.stopBroadcast();

        vm.startBroadcast(vpPk);
        trade.approveRequest(requestId);
        vm.stopBroadcast();

        vm.startBroadcast(atPk);
        trade.approveRequest(requestId);
        vm.stopBroadcast();

        vm.startBroadcast(adminPk);
        trade.executeRequest(requestId);
        vm.stopBroadcast();

        console2.log("Burn request executed:", requestId);
        console2.log("Final status:", uint256(trade.getRequestStatus(requestId)));
        require(trade.getRequestStatus(requestId) == StoexTypes.RequestStatus.Executed, "burn not executed");
    }
}
