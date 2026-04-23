// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITimelockController
/// @notice Timelock checks and mint-lot hook used by `TradeManager`.
interface ITimelockController {
    function isTimelocked(address wallet) external view returns (bool);

    function getLotTimelockExpiry(uint256 lotId) external view returns (uint256);

    function isWalletTimelockedUntil(address wallet) external view returns (uint256);

    function applyMintLotTimelock(uint256 lotId, uint256 untilTs) external;
}
