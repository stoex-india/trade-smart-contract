// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IGovernanceConfig} from "../interfaces/IGovernanceConfig.sol";

/// @title StoexOpsGuard
/// @notice DEFAULT_ADMIN always passes; OPS_ADMIN passes only when the named capability is enabled on GovernanceConfig.
abstract contract StoexOpsGuard is AccessControlUpgradeable {
    error NotAuthorized();

    function _opsPermissions() internal view virtual returns (IGovernanceConfig);

    function _hasAdminOrOps(address actor, bytes32 cap) internal view returns (bool) {
        if (hasRole(DEFAULT_ADMIN_ROLE, actor)) return true;
        IGovernanceConfig g = _opsPermissions();
        if (address(g) == address(0)) return false;
        return g.hasOpsCapability(actor, cap);
    }

    modifier onlyAdminOrOps(bytes32 cap) {
        if (!_hasAdminOrOps(msg.sender, cap)) revert NotAuthorized();
        _;
    }
}
