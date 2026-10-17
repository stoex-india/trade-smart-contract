// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX — GovernanceConfig
/// @notice Per-asset volume limits, request TTL, display precision, OPS capabilities, and transfer KYC flags.
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {StoexOpsGuard} from "./base/StoexOpsGuard.sol";
import {StoexTypes} from "./libraries/StoexTypes.sol";
import {StoexIds} from "./libraries/StoexIds.sol";
import {StoexRoles} from "./libraries/StoexRoles.sol";
import {IGovernanceConfig} from "./interfaces/IGovernanceConfig.sol";

contract GovernanceConfig is
    Initializable,
    StoexDeployerAdminUpgradeable,
    StoexOpsGuard,
    UUPSUpgradeable,
    IGovernanceConfig
{
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

    mapping(bytes32 cap => bool) private _opsCapabilityEnabled;
    bool public transferSourceKycRequired;
    bool public transferDestKycRequired;

    event PolicyUpdated(string parameter, bytes32 key);
    event NonKycMaxBuyFiatAmountChanged(uint256 amount);
    event AssetPolicySeeded(bytes32 indexed assetId);
    event OpsCapabilitySet(bytes32 indexed cap, bool enabled);
    event TransferKycPolicyUpdated(bool sourceRequired, bool destRequired);

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

        requestExpiryDuration = 7 days;
        uint256 ugPerKg = 1_000_000_000;
        nonKycMaxBuyFiatAmount = 50_000_000;
        minRedeemAmountUg = 10_000_000;
        maxAmountPerTx = 1 * ugPerKg;
        defaultTimelockDuration = 0;
        defaultPrecision = 6;

        _seedAssetPolicy(StoexIds.GOLD, 10 * ugPerKg, 5 * ugPerKg, 1_000);
        _seedAssetPolicy(StoexIds.SILVER, 10 * ugPerKg, 5 * ugPerKg, 1_000);
        _seedOpsCapabilities();
    }

    /// @notice UUPS v5: seed OPS allow-list. Transfer KYC flags default off (non-KYC allowed).
    function initializeV5() external reinitializer(2) onlyRole(DEFAULT_ADMIN_ROLE) {
        version = 5;
        _seedOpsCapabilities();
        transferSourceKycRequired = false;
        transferDestKycRequired = false;
    }

    function _opsPermissions() internal view override returns (IGovernanceConfig) {
        return IGovernanceConfig(address(this));
    }

    function _seedAssetPolicy(bytes32 assetId, uint256 buyCap, uint256 sellCap, uint256 minBuyUg) private {
        _dailyBuyCap[assetId] = buyCap;
        _dailySellCap[assetId] = sellCap;
        _minimumBuyValueInUg[assetId] = minBuyUg;
        _assetPrecision[assetId] = defaultPrecision;
        emit AssetPolicySeeded(assetId);
    }

    function _seedOpsCapabilities() private {
        _opsCapabilityEnabled[StoexRoles.OPS_REGISTER_USER] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_VERIFY_KYC] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_WHITELIST_WALLET] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_SUSPEND_WALLET] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_UNSUSPEND_WALLET] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_SET_USER_BLOCKED] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_SET_WALLET_RISK] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_APPROVE_WALLET_CHANGE] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_EXECUTE_REQUEST] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_REJECT_REQUEST] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_RESET_NON_KYC_FIAT] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_SET_POLICY] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_TRANSFER_ASSET] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_MINT_CERTIFICATE] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_UPDATE_METADATA] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_NOMINEE_TRANSFER] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_SET_TIMELOCK] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_OVERRIDE_TIMELOCK] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_MANAGE_ASSETS] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_MANAGE_PROVIDERS] = true;
        _opsCapabilityEnabled[StoexRoles.OPS_RECONCILE_TRADE] = true;
    }

    function setOpsCapability(bytes32 cap, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (cap == bytes32(0)) revert ZeroCap();
        _opsCapabilityEnabled[cap] = enabled;
        emit OpsCapabilitySet(cap, enabled);
    }

    function opsCapabilityEnabled(bytes32 cap) external view returns (bool) {
        return _opsCapabilityEnabled[cap];
    }

    function hasOpsCapability(address account, bytes32 cap) public view override returns (bool) {
        return hasRole(StoexRoles.OPS_ADMIN_ROLE, account) && _opsCapabilityEnabled[cap];
    }

    function setTransferSourceKycRequired(bool required) external onlyAdminOrOps(StoexRoles.OPS_SET_POLICY) {
        transferSourceKycRequired = required;
        emit TransferKycPolicyUpdated(transferSourceKycRequired, transferDestKycRequired);
    }

    function setTransferDestKycRequired(bool required) external onlyAdminOrOps(StoexRoles.OPS_SET_POLICY) {
        transferDestKycRequired = required;
        emit TransferKycPolicyUpdated(transferSourceKycRequired, transferDestKycRequired);
    }

    function setNonKycMaxBuyFiatAmount(uint256 amount) external onlyAdminOrOps(StoexRoles.OPS_SET_POLICY) {
        nonKycMaxBuyFiatAmount = amount;
        emit NonKycMaxBuyFiatAmountChanged(amount);
    }

    function setDailyCapForAsset(bytes32 assetId, StoexTypes.RequestType rt, uint256 cap)
        external
        onlyAdminOrOps(StoexRoles.OPS_SET_POLICY)
    {
        if (rt == StoexTypes.RequestType.Buy) _dailyBuyCap[assetId] = cap;
        else if (rt == StoexTypes.RequestType.Sell) _dailySellCap[assetId] = cap;
        else revert InvalidRequestType();
        emit PolicyUpdated("dailyCap", assetId);
    }

    function setMinimumBuyValueInUg(bytes32 assetId, uint256 valueUg)
        external
        onlyAdminOrOps(StoexRoles.OPS_SET_POLICY)
    {
        _minimumBuyValueInUg[assetId] = valueUg;
        emit PolicyUpdated("minimumBuyValueInUg", assetId);
    }

    function setAssetPrecision(bytes32 assetId, uint8 decimals_) external onlyAdminOrOps(StoexRoles.OPS_SET_POLICY) {
        if (decimals_ == 0 || decimals_ > 18) revert InvalidPrecision();
        _assetPrecision[assetId] = decimals_;
        emit PolicyUpdated("assetPrecision", assetId);
    }

    function dailyBuyCap(bytes32 assetId) external view override returns (uint256) {
        return _dailyBuyCap[assetId];
    }

    function dailySellCap(bytes32 assetId) external view override returns (uint256) {
        return _dailySellCap[assetId];
    }

    function minimumBuyValueInUg(bytes32 assetId) external view override returns (uint256) {
        return _minimumBuyValueInUg[assetId];
    }

    function assetPrecision(bytes32 assetId) external view override returns (uint8) {
        uint8 p = _assetPrecision[assetId];
        return p == 0 ? defaultPrecision : p;
    }

    function setMinRedeemAmountUg(uint256 amountUg) external onlyAdminOrOps(StoexRoles.OPS_SET_POLICY) {
        minRedeemAmountUg = amountUg;
        emit PolicyUpdated("minRedeemAmountUg", bytes32(0));
    }

    function setRequestExpiry(uint256 seconds_) external onlyAdminOrOps(StoexRoles.OPS_SET_POLICY) {
        requestExpiryDuration = seconds_;
        emit PolicyUpdated("requestExpiryDuration", bytes32(0));
    }

    function setMaxAmountPerTx(uint256 amountUg) external onlyAdminOrOps(StoexRoles.OPS_SET_POLICY) {
        maxAmountPerTx = amountUg;
        emit PolicyUpdated("maxAmountPerTx", bytes32(0));
    }

    function setDefaultTimelockDuration(uint256 seconds_) external onlyAdminOrOps(StoexRoles.OPS_SET_POLICY) {
        defaultTimelockDuration = seconds_;
        emit PolicyUpdated("defaultTimelockDuration", bytes32(0));
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[38] private __gap;

    error ZeroAddress();
    error InvalidRequestType();
    error InvalidPrecision();
    error ZeroCap();
}
