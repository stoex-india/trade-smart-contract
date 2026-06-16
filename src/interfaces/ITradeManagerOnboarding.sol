// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal callback API from `WhitelistRegistry` when a user is onboarded.
interface ITradeManagerOnboarding {
    function grantUserRoleFromRegistry(address user) external;
}
