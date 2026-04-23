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
}
