// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAssetProviderRegistry
/// @notice Asset Provider entities, supported assets, operators, and per-asset routing.
interface IAssetProviderRegistry {
    function isProviderActive(bytes32 providerId) external view returns (bool);

    function providerSupportsAsset(bytes32 providerId, bytes32 assetId) external view returns (bool);

    function isOperator(bytes32 providerId, address wallet) external view returns (bool);

    function getSellPayout(bytes32 providerId, bytes32 assetId) external view returns (address);

    function getRedeemSink(bytes32 providerId, bytes32 assetId) external view returns (address);
}
