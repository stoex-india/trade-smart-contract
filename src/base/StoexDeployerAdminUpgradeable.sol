// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

/// @title StoexDeployerAdminUpgradeable
/// @notice Deployment wallet (`deployer`) calls `setInitialAdmin` once; thereafter `DEFAULT_ADMIN_ROLE` may rotate via `transferAdmin`.
/// @dev Replace direct `AccessControlUpgradeable` inheritance with this contract so `__AccessControl_init` runs in the child initializer.
abstract contract StoexDeployerAdminUpgradeable is AccessControlUpgradeable {
    address public deployer;
    bool public adminInitialized;

    event InitialAdminSet(address indexed admin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    error NotDeployer();
    error AdminAlreadyInitialized();
    error AdminNotInitialized();
    error DeployerZeroAddress();

    function __StoexDeployerAdmin_init_unchained(address deployer_) internal onlyInitializing {
        if (deployer_ == address(0)) revert DeployerZeroAddress();
        deployer = deployer_;
    }

    /// @notice One-time: grants `DEFAULT_ADMIN_ROLE` to `admin`. Callable only by `deployer` from deployment.
    function setInitialAdmin(address admin) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (adminInitialized) revert AdminAlreadyInitialized();
        if (admin == address(0)) revert DeployerZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        adminInitialized = true;
        emit InitialAdminSet(admin);
    }

    /// @notice Rotates `DEFAULT_ADMIN_ROLE` to `newAdmin` (caller must be current admin).
    function transferAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!adminInitialized) revert AdminNotInitialized();
        if (newAdmin == address(0)) revert DeployerZeroAddress();
        address prev = msg.sender;
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, prev);
        emit AdminTransferred(prev, newAdmin);
    }

    uint256[48] private __gapDeployerAdmin;
}
