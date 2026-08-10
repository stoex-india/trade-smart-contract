// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal callback API from `WhitelistRegistry` when a user is onboarded or migrated.
interface ITradeManagerOnboarding {
    function grantUserRoleFromRegistry(address user) external;

    function revokeUserRoleFromRegistry(address user) external;
}
