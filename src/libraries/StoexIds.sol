// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StoexIds
/// @notice Canonical on-chain asset and provider identifiers (`keccak256` of human-readable labels).
library StoexIds {
    bytes32 internal constant GOLD = keccak256("GOLD");
    bytes32 internal constant SILVER = keccak256("SILVER");
}
