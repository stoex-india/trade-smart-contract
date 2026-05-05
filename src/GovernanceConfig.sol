// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — GovernanceConfig
/// @notice Single source of truth for **approval sequencing**, **volume limits**, **request TTL**, and **precision** (Technical PRD v2.0).
/// @dev UUPS upgradeable. Role model:
/// - `DEFAULT_ADMIN_ROLE`: upgrade authority (`_authorizeUpgrade`) and role administration.
/// - `AT_ROLE` (`StoexRoles.AT_ROLE`): Asset Trustee — may change any policy parameter and approval matrices.
/// @notice Gold **amounts** (caps, holdings, lot sizes) are **integer milligrams** (mg). `goldPrecision` is retained for legacy readers; new logic uses raw mg.
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {StoexTypes} from "./libraries/StoexTypes.sol";
import {StoexRoles} from "./libraries/StoexRoles.sol";

contract GovernanceConfig is Initializable, StoexDeployerAdminUpgradeable, UUPSUpgradeable {
    uint8 public version;

    mapping(StoexTypes.RequestType => bytes32[]) private _approvalPolicy;

    uint256 public requestExpiryDuration;
    uint256 public dailyBuyCap;
    uint256 public dailySellCap;
    uint256 public minRedeemQuantity;
    uint256 public maxGramsPerTx;
    uint256 public defaultTimelockDuration;
    uint8 public goldPrecision;

    /// @notice When false, `VP_ROLE` steps are omitted from approval policies for Redeem, Mint, and Burn (read via `getApprovalPolicy`).
    bool public vpRequiredForApprovals;

    /// @notice Max cumulative INR notional (minor units, e.g. paise 1/100 INR) for non-KYC buy path (`WhitelistRegistry.isEligibleForNonKycUser`).
    uint256 public nonKycMaxBuyFiatAmount;

    /// @notice Minimum buy size in **milligrams**; admin may set to 0 to disable the floor (not recommended). Enforced on every `createBuyRequest`.
    uint256 public minimumBuyGoldValueInMg;

    event PolicyUpdated(string parameter, bytes32 key);
    event VpRequirementChanged(bool required);
    event NonKycMaxBuyFiatAmountChanged(uint256 amount);
    event MinimumBuyGoldValueInMgChanged(uint256 valueMg);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice One-time init: records `deployer` (must call `setInitialAdmin`), default caps/TTL from PRD, and default approval policies per `RequestType`.
    function initialize(address deployer_) external initializer {
        if (deployer_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);

        version = 1;
        vpRequiredForApprovals = true;

        requestExpiryDuration = 7 days;
        // Amounts in milligrams (e.g. 10_000 g ≈ 10_000_000 mg daily buy cap)
        uint256 mgPerKg = 1_000_000;
        dailyBuyCap = 10 * mgPerKg;
        dailySellCap = 5 * mgPerKg;
        nonKycMaxBuyFiatAmount = 50_000_000;
        minRedeemQuantity = 10_000;
        maxGramsPerTx = 1 * mgPerKg;
        defaultTimelockDuration = 0;
        goldPrecision = 0;
        minimumBuyGoldValueInMg = 1;

        _setDefaultPolicies();
    }

    /// @notice Toggle whether Verifying Party (`VP_ROLE`) approval is required for Redeem, Mint, and Burn flows.
    function setVpRequiredForApprovals(bool required) external onlyRole(DEFAULT_ADMIN_ROLE) {
        vpRequiredForApprovals = required;
        emit VpRequirementChanged(required);
    }

    function setNonKycMaxBuyFiatAmount(uint256 amount) external onlyRole(StoexRoles.AT_ROLE) {
        nonKycMaxBuyFiatAmount = amount;
        emit NonKycMaxBuyFiatAmountChanged(amount);
    }

    function setMinimumBuyGoldValueInMg(uint256 valueMg) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minimumBuyGoldValueInMg = valueMg;
        emit MinimumBuyGoldValueInMgChanged(valueMg);
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

    /// @notice Replace the ordered approval role list for `rt`. **Buy** is settled automatically in `TradeManager.createBuyRequest`; this policy is unused for Buy unless you fork behavior off-chain.
    function setApprovalPolicy(StoexTypes.RequestType rt, bytes32[] calldata roles) external onlyRole(StoexRoles.AT_ROLE) {
        delete _approvalPolicy[rt];
        for (uint256 i = 0; i < roles.length; i++) {
            _approvalPolicy[rt].push(roles[i]);
        }
        emit PolicyUpdated("approvalPolicy", bytes32(uint256(uint8(rt))));
    }

    function setDailyCap(StoexTypes.RequestType rt, uint256 cap) external onlyRole(StoexRoles.AT_ROLE) {
        if (rt == StoexTypes.RequestType.Buy) dailyBuyCap = cap;
        else if (rt == StoexTypes.RequestType.Sell) dailySellCap = cap;
        else revert InvalidRequestType();
        emit PolicyUpdated("dailyCap", bytes32(uint256(uint8(rt))));
    }

    function setMinRedeemQuantity(uint256 grams) external onlyRole(StoexRoles.AT_ROLE) {
        minRedeemQuantity = grams;
        emit PolicyUpdated("minRedeemQuantity", bytes32(0));
    }

    function setRequestExpiry(uint256 seconds_) external onlyRole(StoexRoles.AT_ROLE) {
        requestExpiryDuration = seconds_;
        emit PolicyUpdated("requestExpiryDuration", bytes32(0));
    }

    function setMaxGramsPerTx(uint256 grams) external onlyRole(StoexRoles.AT_ROLE) {
        maxGramsPerTx = grams;
        emit PolicyUpdated("maxGramsPerTx", bytes32(0));
    }

    function setDefaultTimelockDuration(uint256 seconds_) external onlyRole(StoexRoles.AT_ROLE) {
        defaultTimelockDuration = seconds_;
        emit PolicyUpdated("defaultTimelockDuration", bytes32(0));
    }

    function setGoldPrecision(uint8 decimals_) external onlyRole(StoexRoles.AT_ROLE) {
        goldPrecision = decimals_;
        emit PolicyUpdated("goldPrecision", bytes32(0));
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

    error ZeroAddress();
    error InvalidRequestType();
}
