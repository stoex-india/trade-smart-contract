// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AssetRegistry
/// @notice Canonical catalog of tradeable assets (Gold, Silver, future metals).
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {StoexOpsGuard} from "./base/StoexOpsGuard.sol";
import {StoexTypes} from "./libraries/StoexTypes.sol";
import {StoexRoles} from "./libraries/StoexRoles.sol";
import {IAssetRegistry} from "./interfaces/IAssetRegistry.sol";
import {IGovernanceConfig} from "./interfaces/IGovernanceConfig.sol";

contract AssetRegistry is Initializable, StoexDeployerAdminUpgradeable, StoexOpsGuard, UUPSUpgradeable, IAssetRegistry {
    uint8 public version;

    mapping(bytes32 assetId => StoexTypes.AssetConfig) private _assets;
    IGovernanceConfig public governance;

    event AssetRegistered(bytes32 indexed assetId, string symbol, string name);
    event AssetUpdated(bytes32 indexed assetId, bool active);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployer_) external initializer {
        if (deployer_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);
        version = 5;
    }

    function initializeV5(address governance_) external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        if (governance_ == address(0)) revert ZeroAddress();
        governance = IGovernanceConfig(governance_);
        version = 5;
    }

    function _opsPermissions() internal view override returns (IGovernanceConfig) {
        return governance;
    }

    function setGovernance(address governance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (governance_ == address(0)) revert ZeroAddress();
        governance = IGovernanceConfig(governance_);
    }

    function registerAsset(bytes32 assetId, string calldata symbol, string calldata name, uint8 precision)
        external
        onlyAdminOrOps(StoexRoles.OPS_MANAGE_ASSETS)
    {
        if (assetId == bytes32(0)) revert ZeroAssetId();
        if (bytes(symbol).length == 0) revert EmptySymbol();
        _assets[assetId] =
            StoexTypes.AssetConfig({symbol: symbol, name: name, active: true, registered: true, precision: precision});
        emit AssetRegistered(assetId, symbol, name);
    }

    function setAssetActive(bytes32 assetId, bool active) external onlyAdminOrOps(StoexRoles.OPS_MANAGE_ASSETS) {
        if (!_assets[assetId].registered) revert UnknownAsset();
        _assets[assetId].active = active;
        emit AssetUpdated(assetId, active);
    }

    function isActive(bytes32 assetId) external view override returns (bool) {
        StoexTypes.AssetConfig storage a = _assets[assetId];
        return a.registered && a.active;
    }

    function getAsset(bytes32 assetId) external view override returns (StoexTypes.AssetConfig memory) {
        return _assets[assetId];
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[47] private __gap;

    error ZeroAddress();
    error ZeroAssetId();
    error EmptySymbol();
    error UnknownAsset();
}
