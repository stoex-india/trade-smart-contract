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

    function minRedeemAmountUg() external view returns (uint256);

    function maxAmountPerTx() external view returns (uint256);

    function defaultTimelockDuration() external view returns (uint256);

    /// @notice Display precision for grams when converting off-chain (6 = microgram base unit per gram).
    function goldPrecision() external view returns (uint8);

    /// @notice Max cumulative INR notional (minor units, e.g. paise) for non-KYC buy path; enforced against buy `fiat_value`.
    function nonKycMaxBuyFiatAmount() external view returns (uint256);

    /// @notice Minimum buy quantity in micrograms (µg). Set 0 to disable the floor.
    function minimumBuyGoldValueInUg() external view returns (uint256);

    function vpRequiredForApprovals() external view returns (bool);
}
