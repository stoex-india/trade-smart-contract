// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexTypes} from "../libraries/StoexTypes.sol";

/// @title IWhitelistRegistry
/// @notice Minimal read API for `GoldNFT` / `TradeManager` eligibility checks.
interface IWhitelistRegistry {
    function isEligible(address wallet) external view returns (bool);

    function getProfile(address wallet) external view returns (StoexTypes.UserProfile memory);
}
