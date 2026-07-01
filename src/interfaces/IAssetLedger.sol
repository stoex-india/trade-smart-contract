// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexTypes} from "../libraries/StoexTypes.sol";

/// @title IAssetLedger
/// @notice Multi-asset, multi-provider certificate ledger and inventory accounting.
interface IAssetLedger {
    function userHolding(address user, bytes32 assetId, bytes32 providerId) external view returns (uint256);

    function userActiveProvider(address user, bytes32 assetId) external view returns (bytes32);

    function providerPoolBalance(bytes32 assetId, bytes32 providerId) external view returns (uint256);

    function totalSupply(bytes32 assetId) external view returns (uint256);

    function circulatingSupply(bytes32 assetId) external view returns (uint256);

    function tokenIdByBeneficiary(address beneficiary, bytes32 assetId) external view returns (uint256);

    function beneficiaryOfToken(uint256 tokenId) external view returns (address);

    function tokenAssetId(uint256 tokenId) external view returns (bytes32);

    function getUserLotIds(address beneficiary, bytes32 assetId) external view returns (uint256[] memory);

    function getPoolLotIds(bytes32 assetId, bytes32 providerId) external view returns (uint256[] memory);

    function mintCertificate(bytes32 assetId, address user) external;

    function mintCertificateForTrade(bytes32 assetId, address user) external;

    function mintToPool(
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        StoexTypes.MintLotMeta calldata lot,
        uint256 requestId
    ) external returns (uint256 lotId);

    function burnFromPool(bytes32 assetId, bytes32 providerId, uint256 amountUg, uint256 requestId) external;

    function decreaseSupply(
        bytes32 assetId,
        bytes32 providerId,
        address user,
        uint256 amountUg,
        StoexTypes.TxType txType,
        uint256 requestId
    ) external;

    function transferFromAPToUser(
        bytes32 assetId,
        bytes32 providerId,
        address user,
        uint256 amountUg,
        StoexTypes.MintLotMeta calldata lot,
        uint256 requestId,
        StoexTypes.TxType historyKind
    ) external returns (uint256 lotId);
}
