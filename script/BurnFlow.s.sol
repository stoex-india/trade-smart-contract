// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";

/// @title BurnFlow
/// @dev Removed in V1 — provider inventory is no longer burned on-chain.
contract BurnFlow is Script {
    function run() external pure {
        revert("BurnFlow removed in V1: no on-chain mint/burn");
    }
}
