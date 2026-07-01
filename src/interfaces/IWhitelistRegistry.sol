// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexTypes} from "../libraries/StoexTypes.sol";

/// @title IWhitelistRegistry
/// @notice Minimal read API for `AssetLedger` / `TradeManager` eligibility checks.
interface IWhitelistRegistry {
    /// @notice Full platform eligibility: KYC verified, whitelisted wallet, active, within risk policy.
    function isEligible(address wallet) external view returns (bool);

    /// @notice Registered user who is not yet KYC-verified may buy only (non-KYC path), subject to `GovernanceConfig.nonKycMaxBuyFiatAmount` (not sell/redeem/mint paths).
    function isEligibleForNonKycUser(address wallet) external view returns (bool);

    function getProfile(address wallet) external view returns (StoexTypes.UserProfile memory);

    /// @notice True when `wallet` holds `USER_ROLE` on the registry (onboarded investor).
    function hasUserRole(address wallet) external view returns (bool);
}
