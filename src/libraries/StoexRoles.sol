// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — StoexRoles
/// @notice Canonical `bytes32` role constants (`keccak256("ROLE_NAME")`) shared across all upgradeable contracts (PRD RBAC).
/// @dev `TRADE_MANAGER_ROLE` is granted to the TradeManager proxy so it can mutate supply and escrow.
///      `OPS_ADMIN_ROLE` is granted on GovernanceConfig only; other contracts query `hasOpsCapability`.
library StoexRoles {
    bytes32 internal constant AP_ROLE = keccak256("AP_ROLE");
    bytes32 internal constant VP_ROLE = keccak256("VP_ROLE");
    bytes32 internal constant AT_ROLE = keccak256("AT_ROLE");
    bytes32 internal constant PAP_ROLE = keccak256("PAP_ROLE");
    bytes32 internal constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 internal constant USER_ROLE = keccak256("USER_ROLE");
    /// @dev Granted to TradeManager proxy so it can mutate supply and escrow.
    bytes32 internal constant TRADE_MANAGER_ROLE = keccak256("TRADE_MANAGER_ROLE");
    /// @dev Operations admin. Held on GovernanceConfig; gated by named capability flags.
    bytes32 internal constant OPS_ADMIN_ROLE = keccak256("OPS_ADMIN_ROLE");

    bytes32 internal constant OPS_REGISTER_USER = keccak256("OPS_REGISTER_USER");
    bytes32 internal constant OPS_WHITELIST_WALLET = keccak256("OPS_WHITELIST_WALLET");
    bytes32 internal constant OPS_SUSPEND_WALLET = keccak256("OPS_SUSPEND_WALLET");
    bytes32 internal constant OPS_UNSUSPEND_WALLET = keccak256("OPS_UNSUSPEND_WALLET");
    bytes32 internal constant OPS_SET_USER_BLOCKED = keccak256("OPS_SET_USER_BLOCKED");
    bytes32 internal constant OPS_SET_WALLET_RISK = keccak256("OPS_SET_WALLET_RISK");
    bytes32 internal constant OPS_APPROVE_WALLET_CHANGE = keccak256("OPS_APPROVE_WALLET_CHANGE");
    bytes32 internal constant OPS_EXECUTE_REQUEST = keccak256("OPS_EXECUTE_REQUEST");
    bytes32 internal constant OPS_REJECT_REQUEST = keccak256("OPS_REJECT_REQUEST");
    bytes32 internal constant OPS_RESET_NON_KYC_FIAT = keccak256("OPS_RESET_NON_KYC_FIAT");
    bytes32 internal constant OPS_SET_POLICY = keccak256("OPS_SET_POLICY");
    bytes32 internal constant OPS_TRANSFER_ASSET = keccak256("OPS_TRANSFER_ASSET");
    bytes32 internal constant OPS_MINT_CERTIFICATE = keccak256("OPS_MINT_CERTIFICATE");
    bytes32 internal constant OPS_UPDATE_METADATA = keccak256("OPS_UPDATE_METADATA");
    bytes32 internal constant OPS_NOMINEE_TRANSFER = keccak256("OPS_NOMINEE_TRANSFER");
    bytes32 internal constant OPS_SET_TIMELOCK = keccak256("OPS_SET_TIMELOCK");
    bytes32 internal constant OPS_OVERRIDE_TIMELOCK = keccak256("OPS_OVERRIDE_TIMELOCK");
    bytes32 internal constant OPS_MANAGE_ASSETS = keccak256("OPS_MANAGE_ASSETS");
    bytes32 internal constant OPS_MANAGE_PROVIDERS = keccak256("OPS_MANAGE_PROVIDERS");
    bytes32 internal constant OPS_RECONCILE_TRADE = keccak256("OPS_RECONCILE_TRADE");
}
