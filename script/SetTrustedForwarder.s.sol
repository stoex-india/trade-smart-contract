// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {TradeManager} from "../src/TradeManager.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {GoldNFT} from "../src/GoldNFT.sol";

/// @title SetTrustedForwarder
/// @notice Rotates trusted forwarder on all ERC-2771-aware contracts.
/// @dev Required env: `PRIVATE_KEY`, `TRADE_MANAGER`, `WHITELIST_REGISTRY`, `GOLD_NFT`,
/// `RELAYER_SMART_CONTRACT` (ERC-2771 trusted forwarder — the contract that directly calls our proxies).
contract SetTrustedForwarder is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address forwarder = vm.envAddress("RELAYER_SMART_CONTRACT");
        if (forwarder == address(0)) revert("RELAYER_SMART_CONTRACT is zero");

        vm.startBroadcast(pk);

        TradeManager(vm.envAddress("TRADE_MANAGER")).setTrustedForwarder(forwarder);
        WhitelistRegistry(vm.envAddress("WHITELIST_REGISTRY")).setTrustedForwarder(forwarder);
        GoldNFT(vm.envAddress("GOLD_NFT")).setTrustedForwarder(forwarder);

        vm.stopBroadcast();

        console2.log("Trusted forwarder updated to", forwarder);
    }
}
