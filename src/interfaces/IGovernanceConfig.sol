// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexTypes} from "../libraries/StoexTypes.sol";

/// @title IGovernanceConfig
/// @notice Read-only policy API consumed by `TradeManager`.
interface IGovernanceConfig {
    function getApprovalPolicy(StoexTypes.RequestType rt) external view returns (bytes32[] memory);

    function requestExpiryDuration() external view returns (uint256);

    function dailyBuyCap() external view returns (uint256);

    function dailySellCap() external view returns (uint256);

    function minRedeemQuantity() external view returns (uint256);

    function maxGramsPerTx() external view returns (uint256);

    function defaultTimelockDuration() external view returns (uint256);

    function goldPrecision() external view returns (uint8);

    /// @notice Max cumulative INR notional (minor units, e.g. paise) for non-KYC buy path; enforced against buy `fiat_value`.
    function nonKycMaxBuyFiatAmount() external view returns (uint256);

    /// @notice Minimum buy quantity in milligrams (set 0 to disable the minimum floor for buys).
    function minimumBuyGoldValueInMg() external view returns (uint256);

    function vpRequiredForApprovals() external view returns (bool);
}
