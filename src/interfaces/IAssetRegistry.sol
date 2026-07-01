// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexTypes} from "../libraries/StoexTypes.sol";

/// @title IAssetRegistry
/// @notice Canonical catalog of tradeable assets.
interface IAssetRegistry {
    function isActive(bytes32 assetId) external view returns (bool);

    function getAsset(bytes32 assetId) external view returns (StoexTypes.AssetConfig memory);
}
