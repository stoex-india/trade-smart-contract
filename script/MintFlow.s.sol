// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {StoexTypes} from "../src/libraries/StoexTypes.sol";

/// @title MintFlow
/// @notice PRD mint flow: AP propose -> VP approve -> AT approve -> ADMIN execute.
contract MintFlow is Script {
    function run() external {
        TradeManager trade = TradeManager(vm.envAddress("TRADE_MANAGER"));

        uint256 adminPk = vm.envOr("ADMIN_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
        uint256 apPk = vm.envOr("AP_PRIVATE_KEY", adminPk);
        uint256 vpPk = vm.envOr("VP_PRIVATE_KEY", adminPk);
        uint256 atPk = vm.envOr("AT_PRIVATE_KEY", adminPk);

        uint256 grams = vm.envOr("MINT_GRAMS", uint256(1000));
        address creditTo = vm.envAddress("MINT_CREDIT_TO");
        bytes32 vaultReceiptId = vm.envOr("MINT_VAULT_RECEIPT_ID", bytes32("VAULT-RCPT-001"));

        StoexTypes.MintLotMeta memory lot = StoexTypes.MintLotMeta({
            vaultReceiptId: vaultReceiptId,
            batchId: vm.envOr("MINT_BATCH_ID", bytes32("BATCH-001")),
            purity: uint16(vm.envOr("MINT_PURITY", uint256(999))),
            depositTimestamp: vm.envOr("MINT_DEPOSIT_TS", block.timestamp),
            apId: vm.envOr("MINT_AP_ID", vm.addr(apPk)),
            vpId: vm.envOr("MINT_VP_ID", vm.addr(vpPk)),
            lockUntilTs: vm.envOr("MINT_LOCK_UNTIL_TS", uint256(0)),
            grams: grams
        });

        vm.startBroadcast(apPk);
        uint256 requestId = trade.proposeMint(grams, creditTo, vaultReceiptId, lot);
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

        console2.log("Mint request executed:", requestId);
        console2.log("Final status:", uint256(trade.getRequestStatus(requestId)));
        require(trade.getRequestStatus(requestId) == StoexTypes.RequestStatus.Executed, "mint not executed");
    }
}
