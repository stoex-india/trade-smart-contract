// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX — GovernanceConfig
/// @notice Approval sequencing, per-asset volume limits, request TTL, and display precision.
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {StoexTypes} from "./libraries/StoexTypes.sol";
import {StoexRoles} from "./libraries/StoexRoles.sol";
import {StoexIds} from "./libraries/StoexIds.sol";

contract GovernanceConfig is Initializable, StoexDeployerAdminUpgradeable, UUPSUpgradeable {
    uint8 public version;

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

    bool public vpRequiredForApprovals;
    uint256 public nonKycMaxBuyFiatAmount;

    event PolicyUpdated(string parameter, bytes32 key);
    event VpRequirementChanged(bool required);
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

        version = 2;
        vpRequiredForApprovals = true;

        requestExpiryDuration = 7 days;
        uint256 ugPerKg = 1_000_000_000;
        nonKycMaxBuyFiatAmount = 50_000_000;
        minRedeemAmountUg = 10_000_000;
        maxAmountPerTx = 1 * ugPerKg;
        defaultTimelockDuration = 0;
        defaultPrecision = 6;

        _seedAssetPolicy(StoexIds.GOLD, 10 * ugPerKg, 5 * ugPerKg, 1_000);
        _seedAssetPolicy(StoexIds.SILVER, 10 * ugPerKg, 5 * ugPerKg, 1_000);

        _setDefaultPolicies();
    }

    function _seedAssetPolicy(bytes32 assetId, uint256 buyCap, uint256 sellCap, uint256 minBuyUg) private {
        _dailyBuyCap[assetId] = buyCap;
        _dailySellCap[assetId] = sellCap;
        _minimumBuyValueInUg[assetId] = minBuyUg;
        _assetPrecision[assetId] = defaultPrecision;
        emit AssetPolicySeeded(assetId);
    }

    function setVpRequiredForApprovals(bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        vpRequiredForApprovals = required;
        emit VpRequirementChanged(required);
    }

    function setNonKycMaxBuyFiatAmount(uint256 amount) external onlyRole(StoexRoles.AT_ROLE) {
        nonKycMaxBuyFiatAmount = amount;
        emit NonKycMaxBuyFiatAmountChanged(amount);
    }

    function setDailyCapForAsset(bytes32 assetId, StoexTypes.RequestType rt, uint256 cap)
        external
        onlyRole(StoexRoles.AT_ROLE)
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

    function setAssetPrecision(bytes32 assetId, uint8 decimals_) external onlyRole(StoexRoles.AT_ROLE) {
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

    function _setDefaultPolicies() private {
        delete _approvalPolicy[StoexTypes.RequestType.Buy];

        delete _approvalPolicy[StoexTypes.RequestType.Sell];
        _approvalPolicy[StoexTypes.RequestType.Sell].push(StoexRoles.AP_ROLE);
        _approvalPolicy[StoexTypes.RequestType.Sell].push(StoexRoles.AT_ROLE);

        delete _approvalPolicy[StoexTypes.RequestType.Redeem];
        _approvalPolicy[StoexTypes.RequestType.Redeem].push(StoexRoles.AP_ROLE);
        _approvalPolicy[StoexTypes.RequestType.Redeem].push(StoexRoles.VP_ROLE);
        _approvalPolicy[StoexTypes.RequestType.Redeem].push(StoexRoles.PAP_ROLE);
        _approvalPolicy[StoexTypes.RequestType.Redeem].push(StoexRoles.AT_ROLE);

        delete _approvalPolicy[StoexTypes.RequestType.Mint];
        _approvalPolicy[StoexTypes.RequestType.Mint].push(StoexRoles.VP_ROLE);
        _approvalPolicy[StoexTypes.RequestType.Mint].push(StoexRoles.AT_ROLE);

        delete _approvalPolicy[StoexTypes.RequestType.Burn];
        _approvalPolicy[StoexTypes.RequestType.Burn].push(StoexRoles.VP_ROLE);
        _approvalPolicy[StoexTypes.RequestType.Burn].push(StoexRoles.AT_ROLE);
    }

    function setApprovalPolicy(StoexTypes.RequestType rt, bytes32[] calldata roles) external onlyRole(StoexRoles.AT_ROLE) {
        delete _approvalPolicy[rt];
        for (uint256 i = 0; i < roles.length; i++) {
            _approvalPolicy[rt].push(roles[i]);
        }
        emit PolicyUpdated("approvalPolicy", bytes32(uint256(uint8(rt))));
    }

    function setMinRedeemAmountUg(uint256 amountUg) external onlyRole(StoexRoles.AT_ROLE) {
        minRedeemAmountUg = amountUg;
        emit PolicyUpdated("minRedeemAmountUg", bytes32(0));
    }

    function setRequestExpiry(uint256 seconds_) external onlyRole(StoexRoles.AT_ROLE) {
        requestExpiryDuration = seconds_;
        emit PolicyUpdated("requestExpiryDuration", bytes32(0));
    }

    function setMaxAmountPerTx(uint256 amountUg) external onlyRole(StoexRoles.AT_ROLE) {
        maxAmountPerTx = amountUg;
        emit PolicyUpdated("maxAmountPerTx", bytes32(0));
    }

    function setDefaultTimelockDuration(uint256 seconds_) external onlyRole(StoexRoles.AT_ROLE) {
        defaultTimelockDuration = seconds_;
        emit PolicyUpdated("defaultTimelockDuration", bytes32(0));
    }

    function getApprovalPolicy(StoexTypes.RequestType rt) external view returns (bytes32[] memory) {
        bytes32[] storage raw = _approvalPolicy[rt];
        bool stripVp = !vpRequiredForApprovals && _usesOptionalVp(rt);
        uint256 n;
        for (uint256 i = 0; i < raw.length; i++) {
            if (stripVp && raw[i] == StoexRoles.VP_ROLE) continue;
            n++;
        }
        bytes32[] memory out = new bytes32[](n);
        uint256 j;
        for (uint256 i = 0; i < raw.length; i++) {
            if (stripVp && raw[i] == StoexRoles.VP_ROLE) continue;
            out[j++] = raw[i];
        }
        return out;
    }

    function _usesOptionalVp(StoexTypes.RequestType rt) private pure returns (bool) {
        return rt == StoexTypes.RequestType.Redeem || rt == StoexTypes.RequestType.Mint || rt == StoexTypes.RequestType.Burn;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[40] private __gap;

    error ZeroAddress();
    error InvalidRequestType();
}
