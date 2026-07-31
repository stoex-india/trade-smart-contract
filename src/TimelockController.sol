// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX — TimelockController
/// @notice Time-based gating for sell and redeem: per-wallet and per-lot locks (V1 — admin-only).
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";

contract TimelockController is Initializable, StoexDeployerAdminUpgradeable, UUPSUpgradeable {
    uint8 public version;

    address public tradeManager;

    mapping(address => uint256) public walletLockUntil;
    mapping(uint256 => uint256) public lotLockUntil;

    event TimelockSet(address indexed wallet, uint256 indexed lotId, uint256 untilTs, bool isWallet);
    event TimelockOverridden(address indexed wallet, uint256 indexed lotId, uint256 requestId, address admin);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployer_) external initializer {
        if (deployer_ == address(0)) revert ZeroAdmin();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);
        version = 2;
    }

    function setTradeManager(address tradeManager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tradeManager_ == address(0)) revert ZeroAddress();
        if (tradeManager != address(0)) revert AlreadySet();
        tradeManager = tradeManager_;
    }

    function setWalletTimelock(address wallet, uint256 untilTs) external onlyRole(DEFAULT_ADMIN_ROLE) {
        walletLockUntil[wallet] = untilTs;
        emit TimelockSet(wallet, 0, untilTs, true);
    }

    function setLotTimelock(uint256 lotId, uint256 untilTs) external onlyRole(DEFAULT_ADMIN_ROLE) {
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

    function overrideTimelock(address wallet, uint256 requestId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        walletLockUntil[wallet] = 0;
        emit TimelockOverridden(wallet, 0, requestId, msg.sender);
    }

    function overrideLotTimelock(uint256 lotId, uint256 requestId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        lotLockUntil[lotId] = 0;
        emit TimelockOverridden(address(0), lotId, requestId, msg.sender);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[49] private __gap;

    error ZeroAdmin();
    error ZeroAddress();
    error AlreadySet();
}
