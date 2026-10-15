// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX — TimelockController
/// @notice Time-based gating for sell and redeem: per-wallet and per-lot locks (V1 — admin-only).
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {StoexOpsGuard} from "./base/StoexOpsGuard.sol";
import {StoexRoles} from "./libraries/StoexRoles.sol";
import {IGovernanceConfig} from "./interfaces/IGovernanceConfig.sol";

contract TimelockController is Initializable, StoexDeployerAdminUpgradeable, StoexOpsGuard, UUPSUpgradeable {
    uint8 public version;

    address public tradeManager;

    mapping(address => uint256) public walletLockUntil;
    mapping(uint256 => uint256) public lotLockUntil;
    /// @dev Max lot-lock expiry per (user, asset). Enables O(1) sell/redeem gates (audit #10).
    mapping(address => mapping(bytes32 => uint256)) public userAssetLotLockMax;

    event TimelockSet(address indexed wallet, uint256 indexed lotId, uint256 untilTs, bool isWallet);
    event TimelockOverridden(address indexed wallet, uint256 indexed lotId, uint256 requestId, address admin);
    event TradeManagerUpdated(address indexed previous, address indexed current);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployer_) external initializer {
        if (deployer_ == address(0)) revert ZeroAdmin();
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

    function setTradeManager(address tradeManager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tradeManager_ == address(0)) revert ZeroAddress();
        address prev = tradeManager;
        tradeManager = tradeManager_;
        emit TradeManagerUpdated(prev, tradeManager_);
    }

    function setWalletTimelock(address wallet, uint256 untilTs) external onlyAdminOrOps(StoexRoles.OPS_SET_TIMELOCK) {
        walletLockUntil[wallet] = untilTs;
        emit TimelockSet(wallet, 0, untilTs, true);
    }

    /// @notice Sets a per-lot lock and updates the O(1) max expiry for `(user, assetId)`.
    function setLotTimelock(address user, bytes32 assetId, uint256 lotId, uint256 untilTs)
        external
        onlyAdminOrOps(StoexRoles.OPS_SET_TIMELOCK)
    {
        if (user == address(0)) revert ZeroAddress();
        lotLockUntil[lotId] = untilTs;
        if (untilTs > userAssetLotLockMax[user][assetId]) {
            userAssetLotLockMax[user][assetId] = untilTs;
        }
        emit TimelockSet(user, lotId, untilTs, false);
    }

    function getTimelockStatus(address wallet) external view returns (bool locked, uint256 untilTs) {
        untilTs = walletLockUntil[wallet];
        locked = untilTs != 0 && block.timestamp < untilTs;
    }

    function getLotTimelockStatus(uint256 lotId) external view returns (bool locked, uint256 untilTs) {
        untilTs = lotLockUntil[lotId];
        locked = untilTs != 0 && block.timestamp < untilTs;
    }

    function getLotTimelockExpiry(uint256 lotId) external view returns (uint256) {
        return lotLockUntil[lotId];
    }

    function isWalletTimelockedUntil(address wallet) external view returns (uint256) {
        return walletLockUntil[wallet];
    }

    function isTimelocked(address wallet) external view returns (bool) {
        uint256 u = walletLockUntil[wallet];
        if (u != 0 && block.timestamp < u) return true;
        return false;
    }

    function isUserAssetLotTimelocked(address user, bytes32 assetId) external view returns (bool) {
        uint256 u = userAssetLotLockMax[user][assetId];
        return u != 0 && block.timestamp < u;
    }

    function overrideTimelock(address wallet, uint256 requestId)
        external
        onlyAdminOrOps(StoexRoles.OPS_OVERRIDE_TIMELOCK)
    {
        walletLockUntil[wallet] = 0;
        emit TimelockOverridden(wallet, 0, requestId, msg.sender);
    }

    /// @notice Clears a lot lock. Also clears the (user, asset) max so sell/redeem is not stuck;
    ///         admin may re-apply remaining lot locks if needed.
    function overrideLotTimelock(address user, bytes32 assetId, uint256 lotId, uint256 requestId)
        external
        onlyAdminOrOps(StoexRoles.OPS_OVERRIDE_TIMELOCK)
    {
        lotLockUntil[lotId] = 0;
        userAssetLotLockMax[user][assetId] = 0;
        emit TimelockOverridden(user, lotId, requestId, msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    IGovernanceConfig public governance;
    uint256[47] private __gap;

    error ZeroAdmin();
    error ZeroAddress();
}
