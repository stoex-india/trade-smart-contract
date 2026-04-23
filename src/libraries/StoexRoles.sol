// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — StoexRoles
/// @notice Canonical `bytes32` role constants (`keccak256("ROLE_NAME")`) shared across all upgradeable contracts (PRD RBAC).
/// @dev `TRADE_MANAGER_ROLE` is granted to the `TradeManager` proxy so it can call `GoldNFT` supply mutators and is **not** the same as the optional ERC-2771 forwarder (not included here).
library StoexRoles {
    bytes32 internal constant AP_ROLE = keccak256("AP_ROLE");
    bytes32 internal constant VP_ROLE = keccak256("VP_ROLE");
    bytes32 internal constant AT_ROLE = keccak256("AT_ROLE");
    bytes32 internal constant PAP_ROLE = keccak256("PAP_ROLE");
    bytes32 internal constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 internal constant USER_ROLE = keccak256("USER_ROLE");
    /// @dev Granted to TradeManager proxy so it can mutate supply and escrow.
    bytes32 internal constant TRADE_MANAGER_ROLE = keccak256("TRADE_MANAGER_ROLE");
}
