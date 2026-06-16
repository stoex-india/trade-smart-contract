// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexTypes} from "../libraries/StoexTypes.sol";

/// @title IGoldNFT
/// @notice External surface used by `EscrowVault` (balance reads) and integration tests.
interface IGoldNFT {
    function userHolding(address user) external view returns (uint256);

    function tokenIdByBeneficiary(address beneficiary) external view returns (uint256);

    function beneficiaryOfToken(uint256 tokenId) external view returns (address);

    function getUserLotIds(address beneficiary) external view returns (uint256[] memory);

    function getPoolLotIds() external view returns (uint256[] memory);

    function mintCertificate(address user) external;

    function mintCertificateForTrade(address user) external;

    /// @notice PRD mint: vaulted gold enters AP buy pool (`totalGoldSupply` and `totalAssetProviderBalance` increase).
    function mintToPool(uint256 amountUg, StoexTypes.MintLotMeta calldata lot, uint256 requestId)
        external
        returns (uint256 lotId);

    /// @notice PRD burn: unsold AP pool inventory is removed (`totalGoldSupply` and `totalAssetProviderBalance` decrease).
    function burnFromPool(uint256 amountUg, uint256 requestId) external;

    function decreaseSupply(address user, uint256 amountUg, StoexTypes.TxType txType, uint256 requestId) external;

    /// @notice Moves micrograms from AP pool to a user (buy path). Does not increase `totalGoldSupply`.
    function transferFromAPToUser(
        address user,
        uint256 amountUg,
        StoexTypes.MintLotMeta calldata lot,
        uint256 requestId,
        StoexTypes.TxType historyKind
    ) external returns (uint256 lotId);

    function totalGoldSupply() external view returns (uint256);

    /// @notice Gold reserved for user buys (Asset Provider pool). Mutated on mint, burn, buy, sell as described in PRD.
    function totalAssetProviderBalance() external view returns (uint256);

    /// @notice Gold held by end users (beneficiaries): `totalGoldSupply - totalAssetProviderBalance`.
    function circulatingSupply() external view returns (uint256);
}
