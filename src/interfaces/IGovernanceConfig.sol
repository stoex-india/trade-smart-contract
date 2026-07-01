// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexTypes} from "../libraries/StoexTypes.sol";

/// @title IGovernanceConfig
/// @notice Read-only policy API consumed by `TradeManager`.
interface IGovernanceConfig {
    function getApprovalPolicy(StoexTypes.RequestType rt) external view returns (bytes32[] memory);

    function requestExpiryDuration() external view returns (uint256);

    function dailyBuyCap(bytes32 assetId) external view returns (uint256);

    function dailySellCap(bytes32 assetId) external view returns (uint256);

    function minRedeemAmountUg() external view returns (uint256);

    function maxAmountPerTx() external view returns (uint256);

    function defaultTimelockDuration() external view returns (uint256);

    function assetPrecision(bytes32 assetId) external view returns (uint8);

    function nonKycMaxBuyFiatAmount() external view returns (uint256);

    function minimumBuyValueInUg(bytes32 assetId) external view returns (uint256);

    function vpRequiredForApprovals() external view returns (bool);
}
