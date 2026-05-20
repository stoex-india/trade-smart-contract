// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexTypes} from "../libraries/StoexTypes.sol";

/// @title IEscrowVault
/// @notice Escrow hooks for `TradeManager` (implementation is `EscrowVault`).
interface IEscrowVault {
    function lockTokens(address wallet, uint256 amountUg, StoexTypes.EscrowReason reason, uint256 requestId) external;

    function unlockTokens(uint256 requestId) external;

    function releaseEscrow(uint256 requestId, address destination) external;

    function getLockedAmount(address wallet) external view returns (uint256);

    function getAvailableBalance(address wallet) external view returns (uint256);

    function getEscrowDetails(uint256 requestId)
        external
        view
        returns (
            address user,
            uint256 amountUg,
            StoexTypes.EscrowReason reasonType,
            uint256 lockedAt,
            bool released
        );
}
