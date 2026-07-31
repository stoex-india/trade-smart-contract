// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

/// @title MintFlow
/// @dev Removed in V1 — provider inventory is no longer minted on-chain.
contract MintFlow is Script {
    function run() external pure {
        revert("MintFlow removed in V1: no on-chain mint/burn; buys increase circulating supply directly");
    }
}
