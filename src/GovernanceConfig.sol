// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX — GovernanceConfig
/// @notice Per-asset volume limits, request TTL, and display precision (V1 — admin-only policy).
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {StoexTypes} from "./libraries/StoexTypes.sol";
import {StoexIds} from "./libraries/StoexIds.sol";

contract GovernanceConfig is Initializable, StoexDeployerAdminUpgradeable, UUPSUpgradeable {
    uint8 public version;

    // Legacy approval-policy slot retained for UUPS layout (unused in V1).
    mapping(StoexTypes.RequestType => bytes32[]) private _approvalPolicy;

    uint256 public requestExpiryDuration;
    uint256 public minRedeemAmountUg;
    uint256 public maxAmountPerTx;
    uint256 public defaultTimelockDuration;
    uint8 public defaultPrecision;

    mapping(bytes32 assetId => uint256) private _dailyBuyCap;
    mapping(bytes32 assetId => uint256) private _dailySellCap;
    mapping(bytes32 assetId => uint256) private _minimumBuyValueInUg;
    mapping(bytes32 assetId => uint8) private _assetPrecision;

    // Legacy VP flag slot retained for UUPS layout (unused in V1).
    bool private _vpRequiredForApprovalsLegacy;
    uint256 public nonKycMaxBuyFiatAmount;

    event PolicyUpdated(string parameter, bytes32 key);
    event NonKycMaxBuyFiatAmountChanged(uint256 amount);
    event AssetPolicySeeded(bytes32 indexed assetId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployer_) external initializer {
        if (deployer_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);

        version = 3;

        requestExpiryDuration = 7 days;
        uint256 ugPerKg = 1_000_000_000;
        nonKycMaxBuyFiatAmount = 50_000_000;
        minRedeemAmountUg = 10_000_000;
        maxAmountPerTx = 1 * ugPerKg;
        defaultTimelockDuration = 0;
        defaultPrecision = 6;

        _seedAssetPolicy(StoexIds.GOLD, 10 * ugPerKg, 5 * ugPerKg, 1_000);
        _seedAssetPolicy(StoexIds.SILVER, 10 * ugPerKg, 5 * ugPerKg, 1_000);
    }

    function _seedAssetPolicy(bytes32 assetId, uint256 buyCap, uint256 sellCap, uint256 minBuyUg) private {
        _dailyBuyCap[assetId] = buyCap;
        _dailySellCap[assetId] = sellCap;
        _minimumBuyValueInUg[assetId] = minBuyUg;
        _assetPrecision[assetId] = defaultPrecision;
        emit AssetPolicySeeded(assetId);
    }

    function setNonKycMaxBuyFiatAmount(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        nonKycMaxBuyFiatAmount = amount;
        emit NonKycMaxBuyFiatAmountChanged(amount);
    }

    function setDailyCapForAsset(bytes32 assetId, StoexTypes.RequestType rt, uint256 cap)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (rt == StoexTypes.RequestType.Buy) _dailyBuyCap[assetId] = cap;
        else if (rt == StoexTypes.RequestType.Sell) _dailySellCap[assetId] = cap;
        else revert InvalidRequestType();
        emit PolicyUpdated("dailyCap", assetId);
    }

    function setMinimumBuyValueInUg(bytes32 assetId, uint256 valueUg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _minimumBuyValueInUg[assetId] = valueUg;
        emit PolicyUpdated("minimumBuyValueInUg", assetId);
    }

    function setAssetPrecision(bytes32 assetId, uint8 decimals_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _assetPrecision[assetId] = decimals_;
        emit PolicyUpdated("assetPrecision", assetId);
    }

    function dailyBuyCap(bytes32 assetId) external view returns (uint256) {
        return _dailyBuyCap[assetId];
    }

    function dailySellCap(bytes32 assetId) external view returns (uint256) {
        return _dailySellCap[assetId];
    }

    function minimumBuyValueInUg(bytes32 assetId) external view returns (uint256) {
        return _minimumBuyValueInUg[assetId];
    }

    function assetPrecision(bytes32 assetId) external view returns (uint8) {
        uint8 p = _assetPrecision[assetId];
        return p == 0 ? defaultPrecision : p;
    }

    function setMinRedeemAmountUg(uint256 amountUg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minRedeemAmountUg = amountUg;
        emit PolicyUpdated("minRedeemAmountUg", bytes32(0));
    }

    function setRequestExpiry(uint256 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        requestExpiryDuration = seconds_;
        emit PolicyUpdated("requestExpiryDuration", bytes32(0));
    }

    function setMaxAmountPerTx(uint256 amountUg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxAmountPerTx = amountUg;
        emit PolicyUpdated("maxAmountPerTx", bytes32(0));
    }

    function setDefaultTimelockDuration(uint256 seconds_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        defaultTimelockDuration = seconds_;
        emit PolicyUpdated("defaultTimelockDuration", bytes32(0));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[40] private __gap;

    error ZeroAddress();
    error InvalidRequestType();
}
