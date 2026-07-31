// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexTypes} from "../libraries/StoexTypes.sol";

/// @title IAssetLedger
/// @notice Multi-asset, multi-provider certificate ledger and circulating-supply accounting (V1).
interface IAssetLedger {
    function userHolding(address user, bytes32 assetId, bytes32 providerId) external view returns (uint256);

    function userActiveProvider(address user, bytes32 assetId) external view returns (bytes32);

    /// @notice Outstanding µg held by users for `(assetId, providerId)`.
    function circulatingSupply(bytes32 assetId, bytes32 providerId) external view returns (uint256);

    /// @notice Sum of per-provider circulating supply for `assetId`.
    function totalCirculating(bytes32 assetId) external view returns (uint256);

    function lifetimeIssued(bytes32 assetId, bytes32 providerId) external view returns (uint256);

    function lifetimeSoldBack(bytes32 assetId, bytes32 providerId) external view returns (uint256);

    function lifetimeRedeemed(bytes32 assetId, bytes32 providerId) external view returns (uint256);

    function tokenIdByBeneficiary(address beneficiary, bytes32 assetId) external view returns (uint256);

    function beneficiaryOfToken(uint256 tokenId) external view returns (address);

    function tokenAssetId(uint256 tokenId) external view returns (bytes32);

    function getUserLotIds(address beneficiary, bytes32 assetId) external view returns (uint256[] memory);

    function mintCertificate(bytes32 assetId, address user) external;

    function mintCertificateForTrade(bytes32 assetId, address user) external;

    function decreaseSupply(
        bytes32 assetId,
        bytes32 providerId,
        address user,
        uint256 amountUg,
        StoexTypes.TxType txType,
        uint256 requestId
    ) external;

    function creditUserBuy(
        bytes32 assetId,
        bytes32 providerId,
        address user,
        uint256 amountUg,
        uint256 requestId
    ) external returns (uint256 lotId);
}
