// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — TimelockController
/// @notice **Time-based gating** for sell and redeem: per-beneficiary wallet locks and per-`lotId` locks (PRD TimelockController).
/// @dev UUPS upgradeable.
/// - `AP_ROLE` may set wallet or lot expiry timestamps (`setWalletTimelock`, `setLotTimelock`).
/// - `AT_ROLE` may clear locks for audit (`overrideTimelock`, `overrideLotTimelock`).
/// - `applyMintLotTimelock` is restricted to the registered `tradeManager` so `TradeManager` can apply `GovernanceConfig.defaultTimelockDuration` after a mint executes without granting AP to `TradeManager`.
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexRoles} from "./libraries/StoexRoles.sol";

contract TimelockController is Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    uint8 public version;

    address public tradeManager;

    mapping(address => uint256) public walletLockUntil;
    mapping(uint256 => uint256) public lotLockUntil;

    event TimelockSet(address indexed wallet, uint256 indexed lotId, uint256 untilTs, bool isWallet);
    event TimelockOverridden(address indexed wallet, uint256 indexed lotId, uint256 requestId, address trustee);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin) external initializer {
        if (admin == address(0)) revert ZeroAdmin();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        version = 1;
    }

    function setTradeManager(address tradeManager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tradeManager_ == address(0)) revert ZeroAddress();
        if (tradeManager != address(0)) revert AlreadySet();
        tradeManager = tradeManager_;
    }

    /// @dev Called when an approved mint is executed so default policy timelocks can be applied without AP_ROLE on TradeManager.
    function applyMintLotTimelock(uint256 lotId, uint256 untilTs) external {
        if (msg.sender != tradeManager) revert NotTradeManager();
        lotLockUntil[lotId] = untilTs;
        emit TimelockSet(address(0), lotId, untilTs, false);
    }

    function setWalletTimelock(address wallet, uint256 untilTs) external onlyRole(StoexRoles.AP_ROLE) {
        walletLockUntil[wallet] = untilTs;
        emit TimelockSet(wallet, 0, untilTs, true);
    }

    function setLotTimelock(uint256 lotId, uint256 untilTs) external onlyRole(StoexRoles.AP_ROLE) {
        lotLockUntil[lotId] = untilTs;
        emit TimelockSet(address(0), lotId, untilTs, false);
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

    function overrideTimelock(address wallet, uint256 requestId) external onlyRole(StoexRoles.AT_ROLE) {
        walletLockUntil[wallet] = 0;
        emit TimelockOverridden(wallet, 0, requestId, msg.sender);
    }

    function overrideLotTimelock(uint256 lotId, uint256 requestId) external onlyRole(StoexRoles.AT_ROLE) {
        lotLockUntil[lotId] = 0;
        emit TimelockOverridden(address(0), lotId, requestId, msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[49] private __gap;

    error ZeroAdmin();
    error ZeroAddress();
    error AlreadySet();
    error NotTradeManager();
}
