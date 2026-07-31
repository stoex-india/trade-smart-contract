// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITimelockController
/// @notice Timelock checks used by `TradeManager` for sell/redeem create gates.
interface ITimelockController {
    function isTimelocked(address wallet) external view returns (bool);

    function getLotTimelockExpiry(uint256 lotId) external view returns (uint256);

    function isWalletTimelockedUntil(address wallet) external view returns (uint256);
}
