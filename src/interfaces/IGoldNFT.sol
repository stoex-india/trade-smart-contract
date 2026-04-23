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

    function mintCertificate(address user) external;

    function mintCertificateForTrade(address user) external;

    function increaseSupply(
        address user,
        uint256 grams,
        StoexTypes.MintLotMeta calldata lot,
        uint256 requestId,
        StoexTypes.TxType historyKind
    ) external returns (uint256 lotId);

    function decreaseSupply(address user, uint256 grams, StoexTypes.TxType txType, uint256 requestId) external;

    function totalGoldSupply() external view returns (uint256);
}
