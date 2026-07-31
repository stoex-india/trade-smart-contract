// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

/// @title GovernanceAdminFlags
/// @dev VP approval flag removed in V1 (no multi-party approvals).
contract GovernanceAdminFlags is Script {
    function run() external pure {
        revert("GovernanceAdminFlags removed in V1: vpRequiredForApprovals no longer used");
    }
}
