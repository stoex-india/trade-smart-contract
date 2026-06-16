// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — GoldNFT
/// @notice **Soulbound** ERC-721 certificate: at most one token per **beneficiary** (economic owner). ERC-721 `ownerOf` is **custody** (may differ after nominee transfer).
/// @dev UUPS upgradeable. Supply accounting:
/// - `totalGoldSupply`: canonical **micrograms (µg)** on-chain; increases on PRD mint (`mintToPool`), decreases on redeem/burn (`decreaseSupply` / `burnFromPool`).
/// - `totalAssetProviderBalance`: unsold AP retail pool; increases on mint (`mintToPool`) and sell returns; decreases on buy (`transferFromAPToUser`) and burn (`burnFromPool`).
/// - `circulatingSupply()` = `totalGoldSupply - totalAssetProviderBalance` (µg with users vs pool).
/// - `userHolding` tracks micrograms per beneficiary.
/// - `mintToPool` / `burnFromPool` / `transferFromAPToUser` / `decreaseSupply` are restricted to `TRADE_MANAGER_ROLE`.
/// - `mintCertificate` is `AP_ROLE`; `mintCertificateForTrade` is `TRADE_MANAGER_ROLE` for automated first purchase/mint execution.
/// - Transfers are blocked in `_update` except mint/burn/admin nominee flow (`_nomineeTransferActive`).
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721URIStorageUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

import {StoexTypes} from "./libraries/StoexTypes.sol";
import {StoexRoles} from "./libraries/StoexRoles.sol";
import {IWhitelistRegistry} from "./interfaces/IWhitelistRegistry.sol";
import {IGoldNFT} from "./interfaces/IGoldNFT.sol";

contract GoldNFT is
    Initializable,
    ERC721URIStorageUpgradeable,
    StoexDeployerAdminUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable,
    IGoldNFT
{
    uint8 public version;
    IWhitelistRegistry public whitelistRegistry;

    uint256 public totalGoldSupply;
    uint256 public nextTokenId;
    uint256 private _nextLotId;

    mapping(address => uint256) public userHolding;
    mapping(address => uint256) public tokenIdByBeneficiary;
    mapping(uint256 => address) public beneficiaryOfToken;
    mapping(uint256 => StoexTypes.MintLotMeta) private _mintLots;
    mapping(address => uint256[]) private _userLotIds;
    uint256[] private _poolLotIds;

    mapping(address => StoexTypes.TxRecord[]) private _txHistory;

    bool private _nomineeTransferActive;
    address private _trustedForwarderValue;

    string private _baseTokenUri;

    event CertificateMinted(address indexed user, uint256 tokenId);
    event SupplyIncreased(uint256 amountUg, address indexed user, uint256 lotId);
    event SupplyDecreased(uint256 amountUg, address indexed user, StoexTypes.TxType txType);
    event PoolInventoryMinted(uint256 amountUg, uint256 lotId, uint256 requestId);
    event PoolInventoryBurned(uint256 amountUg, uint256 requestId);
    event MetadataUpdated(uint256 tokenId, string uri);
    event NomineeTransferred(address indexed fromBeneficiary, address indexed toCustody, uint256 tokenId);
    event WhitelistRegistryUpdated(address registry);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() ERC2771ContextUpgradeable(address(0)) {
        _disableInitializers();
    }

    function initialize(address deployer_, address whitelistRegistry_, address trustedForwarder_) external initializer {
        if (deployer_ == address(0) || whitelistRegistry_ == address(0) || trustedForwarder_ == address(0)) revert ZeroAddress();

        __ERC721_init("STOEX Gold Certificate", "STOEX-AU");
        __ERC721URIStorage_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);

        whitelistRegistry = IWhitelistRegistry(whitelistRegistry_);
        _trustedForwarderValue = trustedForwarder_;
        version = 1;
    }

    /// @notice Updates trusted ERC-2771 forwarder for gasless `GoldNFT` calls.
    function setTrustedForwarder(address trustedForwarder_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (trustedForwarder_ == address(0)) revert ZeroAddress();
        _trustedForwarderValue = trustedForwarder_;
    }

    function trustedForwarder() public view override returns (address) {
        return _trustedForwarderValue;
    }

    function setWhitelistRegistry(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (registry == address(0)) revert ZeroAddress();
        whitelistRegistry = IWhitelistRegistry(registry);
        emit WhitelistRegistryUpdated(registry);
    }

    function setBaseURI(string calldata baseUri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenUri = baseUri;
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenUri;
    }

    function mintCertificate(address user) external onlyRole(StoexRoles.AP_ROLE) whenNotPaused nonReentrant {
        _mintCertificate(user);
    }

    function mintCertificateForTrade(address user) external onlyRole(StoexRoles.TRADE_MANAGER_ROLE) whenNotPaused nonReentrant {
        _mintCertificate(user);
    }

    function _mintCertificate(address user) internal {
        if (!_canReceiveBuyOrCertificate(user)) revert NotEligible();
        if (tokenIdByBeneficiary[user] != 0) revert AlreadyHasCertificate();

        uint256 tokenId = ++nextTokenId;
        tokenIdByBeneficiary[user] = tokenId;
        beneficiaryOfToken[tokenId] = user;
        _safeMint(user, tokenId);

        emit CertificateMinted(user, tokenId);
    }

    /// @notice PRD mint path: tokenize vaulted gold into the AP buy pool (no user credit).
    function mintToPool(uint256 amountUg, StoexTypes.MintLotMeta calldata lot, uint256 requestId)
        external
        override
        onlyRole(StoexRoles.TRADE_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 lotId)
    {
        if (amountUg == 0) revert ZeroAmount();

        lotId = ++_nextLotId;
        StoexTypes.MintLotMeta memory m = lot;
        m.amountUg = amountUg;
        _mintLots[lotId] = m;
        _poolLotIds.push(lotId);

        totalGoldSupply += amountUg;
        totalAssetProviderBalance += amountUg;

        emit PoolInventoryMinted(amountUg, lotId, requestId);
    }

    /// @notice PRD burn path: remove unsold inventory from the AP buy pool.
    function burnFromPool(uint256 amountUg, uint256 requestId)
        external
        override
        onlyRole(StoexRoles.TRADE_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (amountUg == 0) revert ZeroAmount();
        if (totalAssetProviderBalance < amountUg) revert InsufficientPoolInventory();

        totalGoldSupply -= amountUg;
        totalAssetProviderBalance -= amountUg;

        emit PoolInventoryBurned(amountUg, requestId);
    }

    function decreaseSupply(address user, uint256 amountUg, StoexTypes.TxType txType, uint256 requestId)
        external
        override
        onlyRole(StoexRoles.TRADE_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (!whitelistRegistry.isEligible(user)) revert NotEligible();
        if (amountUg == 0) revert ZeroAmount();
        if (userHolding[user] < amountUg) revert InsufficientBalance();

        userHolding[user] -= amountUg;
        if (txType == StoexTypes.TxType.Sell) {
            totalAssetProviderBalance += amountUg;
        } else {
            totalGoldSupply -= amountUg;
        }

        _txHistory[user].push(
            StoexTypes.TxRecord({txType: txType, amountUg: amountUg, timestamp: block.timestamp, requestId: requestId})
        );

        emit SupplyDecreased(amountUg, user, txType);
    }

    /// @inheritdoc IGoldNFT
    function transferFromAPToUser(
        address user,
        uint256 amountUg,
        StoexTypes.MintLotMeta calldata lot,
        uint256 requestId,
        StoexTypes.TxType historyKind
    )
        external
        override
        onlyRole(StoexRoles.TRADE_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 lotId)
    {
        if (!_canReceiveBuyOrCertificate(user)) revert NotEligible();
        if (tokenIdByBeneficiary[user] == 0) revert NoCertificate();
        if (amountUg == 0) revert ZeroAmount();
        if (totalAssetProviderBalance < amountUg) revert InsufficientPoolInventory();

        totalAssetProviderBalance -= amountUg;

        lotId = ++_nextLotId;
        StoexTypes.MintLotMeta memory m = lot;
        m.amountUg = amountUg;
        _mintLots[lotId] = m;
        _userLotIds[user].push(lotId);

        userHolding[user] += amountUg;

        _txHistory[user].push(
            StoexTypes.TxRecord({
                txType: historyKind,
                amountUg: amountUg,
                timestamp: block.timestamp,
                requestId: requestId
            })
        );

        emit SupplyIncreased(amountUg, user, lotId);
    }

    function updateMetadata(uint256 tokenId, string calldata newUri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireOwned(tokenId);
        _setTokenURI(tokenId, newUri);
        emit MetadataUpdated(tokenId, newUri);
    }

    function nomineeTransfer(address fromBeneficiary, address toCustody) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused nonReentrant {
        if (!whitelistRegistry.isEligible(fromBeneficiary) || !whitelistRegistry.isEligible(toCustody)) revert NotEligible();
        uint256 tokenId = tokenIdByBeneficiary[fromBeneficiary];
        if (tokenId == 0) revert NoCertificate();
        if (beneficiaryOfToken[tokenId] != fromBeneficiary) revert InvalidBeneficiary();

        address currentOwner = ownerOf(tokenId);
        _nomineeTransferActive = true;
        _transfer(currentOwner, toCustody, tokenId);
        _nomineeTransferActive = false;

        emit NomineeTransferred(fromBeneficiary, toCustody, tokenId);
    }

    function getUserHolding(address user) external view returns (uint256) {
        return userHolding[user];
    }

    function getMintLot(uint256 lotId) external view returns (StoexTypes.MintLotMeta memory) {
        return _mintLots[lotId];
    }

    function getUserLotIds(address beneficiary) external view returns (uint256[] memory) {
        return _userLotIds[beneficiary];
    }

    function getPoolLotIds() external view returns (uint256[] memory) {
        return _poolLotIds;
    }

    function getTxHistory(address user, uint256 start, uint256 end) external view returns (StoexTypes.TxRecord[] memory) {
        StoexTypes.TxRecord[] storage h = _txHistory[user];
        if (start > end || end > h.length) revert BadPagination();
        uint256 len = end - start;
        StoexTypes.TxRecord[] memory out = new StoexTypes.TxRecord[](len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = h[start + i];
        }
        return out;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721URIStorageUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _canReceiveBuyOrCertificate(address user) private view returns (bool) {
        return whitelistRegistry.isEligible(user) || whitelistRegistry.isEligibleForNonKycUser(user);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0) && !_nomineeTransferActive) {
            revert Soulbound();
        }
        return super._update(to, tokenId, auth);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function _msgSender()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    /// @inheritdoc IGoldNFT
    function circulatingSupply() external view returns (uint256) {
        return totalGoldSupply - totalAssetProviderBalance;
    }

    uint256 public totalAssetProviderBalance;

    uint256[42] private __gap;

    error ZeroAddress();
    error NotEligible();
    error AlreadyHasCertificate();
    error NoCertificate();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientPoolInventory();
    error InvalidBeneficiary();
    error Soulbound();
    error BadPagination();
}
