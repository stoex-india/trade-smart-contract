// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";

/// @dev Gasless `*For` entrypoints require `msg.sender == RELAYER_SMART_CONTRACT`.
abstract contract RelayerScript is Script {
    function _relayerPk() internal view returns (uint256) {
        return vm.envOr("RELAYER_PRIVATE_KEY", vm.envUint("PRIVATE_KEY"));
    }
}
