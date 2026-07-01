// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AssetLedger
/// @notice Soulbound ERC-721 certificates (one per user per asset) and multi-provider inventory accounting.
/// @dev Amounts are integer micrograms (µg). `providerPoolBalance` is unsold AP retail inventory per (asset, provider).
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
import {IAssetLedger} from "./interfaces/IAssetLedger.sol";

contract AssetLedger is
    Initializable,
    ERC721URIStorageUpgradeable,
    StoexDeployerAdminUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable,
    IAssetLedger
{
    uint8 public version;
    IWhitelistRegistry public whitelistRegistry;

    uint256 public nextTokenId;
    uint256 private _nextLotId;

    mapping(bytes32 assetId => uint256) private _totalSupply;
    mapping(bytes32 assetId => uint256) private _totalPoolBalance;
    mapping(bytes32 assetId => mapping(bytes32 providerId => uint256)) private _providerPoolBalance;
    mapping(address user => mapping(bytes32 assetId => mapping(bytes32 providerId => uint256))) private _userHolding;
    mapping(address user => mapping(bytes32 assetId => bytes32)) private _userActiveProvider;
    mapping(address user => mapping(bytes32 assetId => uint256)) private _tokenIdByBeneficiary;
    mapping(uint256 tokenId => address) public beneficiaryOfToken;
    mapping(uint256 tokenId => bytes32) private _tokenAssetId;
    mapping(uint256 => StoexTypes.MintLotMeta) private _mintLots;
    mapping(address => mapping(bytes32 => uint256[])) private _userLotIds;
    mapping(bytes32 => mapping(bytes32 => uint256[])) private _poolLotIds;
    mapping(address => StoexTypes.TxRecord[]) private _txHistory;

    bool private _nomineeTransferActive;
    address private _trustedForwarderValue;
    string private _baseTokenUri;

    event CertificateMinted(bytes32 indexed assetId, address indexed user, uint256 tokenId);
    event SupplyIncreased(bytes32 indexed assetId, bytes32 indexed providerId, uint256 amountUg, address indexed user, uint256 lotId);
    event SupplyDecreased(bytes32 indexed assetId, bytes32 indexed providerId, uint256 amountUg, address indexed user, StoexTypes.TxType txType);
    event PoolInventoryMinted(bytes32 indexed assetId, bytes32 indexed providerId, uint256 amountUg, uint256 lotId, uint256 requestId);
    event PoolInventoryBurned(bytes32 indexed assetId, bytes32 indexed providerId, uint256 amountUg, uint256 requestId);
    event MetadataUpdated(uint256 tokenId, string uri);
    event NomineeTransferred(address indexed fromBeneficiary, address indexed toCustody, uint256 tokenId);
    event WhitelistRegistryUpdated(address registry);
    event ActiveProviderCleared(address indexed user, bytes32 indexed assetId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() ERC2771ContextUpgradeable(address(0)) {
        _disableInitializers();
    }

    function initialize(address deployer_, address whitelistRegistry_, address trustedForwarder_) external initializer {
        if (deployer_ == address(0) || whitelistRegistry_ == address(0) || trustedForwarder_ == address(0)) revert ZeroAddress();

        __ERC721_init("STOEX Asset Certificate", "STOEX-ASSET");
        __ERC721URIStorage_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);

        whitelistRegistry = IWhitelistRegistry(whitelistRegistry_);
        _trustedForwarderValue = trustedForwarder_;
        version = 2;
    }

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

    function userHolding(address user, bytes32 assetId, bytes32 providerId) external view override returns (uint256) {
        return _userHolding[user][assetId][providerId];
    }

    function userActiveProvider(address user, bytes32 assetId) external view override returns (bytes32) {
        return _userActiveProvider[user][assetId];
    }

    function providerPoolBalance(bytes32 assetId, bytes32 providerId) external view override returns (uint256) {
        return _providerPoolBalance[assetId][providerId];
    }

    function totalSupply(bytes32 assetId) external view override returns (uint256) {
        return _totalSupply[assetId];
    }

    function circulatingSupply(bytes32 assetId) external view override returns (uint256) {
        uint256 supply = _totalSupply[assetId];
        uint256 pool = _totalPoolBalance[assetId];
        return supply > pool ? supply - pool : 0;
    }

    function tokenIdByBeneficiary(address beneficiary, bytes32 assetId) external view override returns (uint256) {
        return _tokenIdByBeneficiary[beneficiary][assetId];
    }

    function tokenAssetId(uint256 tokenId) external view override returns (bytes32) {
        return _tokenAssetId[tokenId];
    }

    function mintCertificate(bytes32 assetId, address user) external onlyRole(StoexRoles.AP_ROLE) whenNotPaused nonReentrant {
        _mintCertificate(assetId, user);
    }

    function mintCertificateForTrade(bytes32 assetId, address user)
        external
        onlyRole(StoexRoles.TRADE_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
    {
        _mintCertificate(assetId, user);
    }

    function _mintCertificate(bytes32 assetId, address user) internal {
        if (assetId == bytes32(0)) revert ZeroAssetId();
        if (!_canReceiveBuyOrCertificate(user)) revert NotEligible();
        if (_tokenIdByBeneficiary[user][assetId] != 0) revert AlreadyHasCertificate();

        uint256 tokenId = ++nextTokenId;
        _tokenIdByBeneficiary[user][assetId] = tokenId;
        beneficiaryOfToken[tokenId] = user;
        _tokenAssetId[tokenId] = assetId;
        _safeMint(user, tokenId);

        emit CertificateMinted(assetId, user, tokenId);
    }

    function mintToPool(
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        StoexTypes.MintLotMeta calldata lot,
        uint256 requestId
    )
        external
        override
        onlyRole(StoexRoles.TRADE_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 lotId)
    {
        if (assetId == bytes32(0) || providerId == bytes32(0)) revert ZeroIds();
        if (amountUg == 0) revert ZeroAmount();
        if (lot.assetId != bytes32(0) && lot.assetId != assetId) revert AssetMismatch();
        if (lot.providerId != bytes32(0) && lot.providerId != providerId) revert ProviderMismatch();

        lotId = ++_nextLotId;
        StoexTypes.MintLotMeta memory m = lot;
        m.assetId = assetId;
        m.providerId = providerId;
        m.amountUg = amountUg;
        _mintLots[lotId] = m;
        _poolLotIds[assetId][providerId].push(lotId);

        _totalSupply[assetId] += amountUg;
        _providerPoolBalance[assetId][providerId] += amountUg;
        _totalPoolBalance[assetId] += amountUg;

        emit PoolInventoryMinted(assetId, providerId, amountUg, lotId, requestId);
    }

    function burnFromPool(bytes32 assetId, bytes32 providerId, uint256 amountUg, uint256 requestId)
        external
        override
        onlyRole(StoexRoles.TRADE_MANAGER_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (assetId == bytes32(0) || providerId == bytes32(0)) revert ZeroIds();
        if (amountUg == 0) revert ZeroAmount();
        if (_providerPoolBalance[assetId][providerId] < amountUg) revert InsufficientPoolInventory();

        _totalSupply[assetId] -= amountUg;
        _providerPoolBalance[assetId][providerId] -= amountUg;
        _totalPoolBalance[assetId] -= amountUg;

        emit PoolInventoryBurned(assetId, providerId, amountUg, requestId);
    }

    function decreaseSupply(
        bytes32 assetId,
        bytes32 providerId,
        address user,
        uint256 amountUg,
        StoexTypes.TxType txType,
        uint256 requestId
    ) external override onlyRole(StoexRoles.TRADE_MANAGER_ROLE) whenNotPaused nonReentrant {
        if (!whitelistRegistry.isEligible(user)) revert NotEligible();
        if (assetId == bytes32(0) || providerId == bytes32(0)) revert ZeroIds();
        if (amountUg == 0) revert ZeroAmount();
        _requireActiveProvider(user, assetId, providerId);
        if (_userHolding[user][assetId][providerId] < amountUg) revert InsufficientBalance();

        _userHolding[user][assetId][providerId] -= amountUg;
        if (txType == StoexTypes.TxType.Sell) {
            _providerPoolBalance[assetId][providerId] += amountUg;
            _totalPoolBalance[assetId] += amountUg;
        } else {
            _totalSupply[assetId] -= amountUg;
        }

        if (_userHolding[user][assetId][providerId] == 0) {
            delete _userActiveProvider[user][assetId];
            emit ActiveProviderCleared(user, assetId);
        }

        _txHistory[user].push(
            StoexTypes.TxRecord({
                assetId: assetId,
                providerId: providerId,
                txType: txType,
                amountUg: amountUg,
                timestamp: block.timestamp,
                requestId: requestId
            })
        );

        emit SupplyDecreased(assetId, providerId, amountUg, user, txType);
    }

    function transferFromAPToUser(
        bytes32 assetId,
        bytes32 providerId,
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
        if (assetId == bytes32(0) || providerId == bytes32(0)) revert ZeroIds();
        if (_tokenIdByBeneficiary[user][assetId] == 0) revert NoCertificate();
        if (amountUg == 0) revert ZeroAmount();
        if (_providerPoolBalance[assetId][providerId] < amountUg) revert InsufficientPoolInventory();

        bytes32 active = _userActiveProvider[user][assetId];
        if (active != bytes32(0) && active != providerId) revert ProviderBindingConflict();

        _providerPoolBalance[assetId][providerId] -= amountUg;
        _totalPoolBalance[assetId] -= amountUg;
        if (active == bytes32(0)) {
            _userActiveProvider[user][assetId] = providerId;
        }

        lotId = ++_nextLotId;
        StoexTypes.MintLotMeta memory m = lot;
        m.assetId = assetId;
        m.providerId = providerId;
        m.amountUg = amountUg;
        _mintLots[lotId] = m;
        _userLotIds[user][assetId].push(lotId);

        _userHolding[user][assetId][providerId] += amountUg;

        _txHistory[user].push(
            StoexTypes.TxRecord({
                assetId: assetId,
                providerId: providerId,
                txType: historyKind,
                amountUg: amountUg,
                timestamp: block.timestamp,
                requestId: requestId
            })
        );

        emit SupplyIncreased(assetId, providerId, amountUg, user, lotId);
    }

    function updateMetadata(uint256 tokenId, string calldata newUri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireOwned(tokenId);
        _setTokenURI(tokenId, newUri);
        emit MetadataUpdated(tokenId, newUri);
    }

    function nomineeTransferForAsset(bytes32 assetId, address fromBeneficiary, address toCustody)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (!whitelistRegistry.isEligible(fromBeneficiary) || !whitelistRegistry.isEligible(toCustody)) revert NotEligible();
        uint256 tokenId = _tokenIdByBeneficiary[fromBeneficiary][assetId];
        if (tokenId == 0) revert NoCertificate();
        if (beneficiaryOfToken[tokenId] != fromBeneficiary) revert InvalidBeneficiary();

        address currentOwner = ownerOf(tokenId);
        _nomineeTransferActive = true;
        _transfer(currentOwner, toCustody, tokenId);
        _nomineeTransferActive = false;

        emit NomineeTransferred(fromBeneficiary, toCustody, tokenId);
    }

    function getMintLot(uint256 lotId) external view returns (StoexTypes.MintLotMeta memory) {
        return _mintLots[lotId];
    }

    function getUserLotIds(address beneficiary, bytes32 assetId) external view override returns (uint256[] memory) {
        return _userLotIds[beneficiary][assetId];
    }

    function getPoolLotIds(bytes32 assetId, bytes32 providerId) external view override returns (uint256[] memory) {
        return _poolLotIds[assetId][providerId];
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

    function _requireActiveProvider(address user, bytes32 assetId, bytes32 providerId) private view {
        if (_userActiveProvider[user][assetId] != providerId) revert ProviderBindingConflict();
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

    uint256[40] private __gap;

    error ZeroAddress();
    error ZeroAssetId();
    error ZeroIds();
    error NotEligible();
    error AlreadyHasCertificate();
    error NoCertificate();
    error ZeroAmount();
    error InsufficientBalance();
    error InsufficientPoolInventory();
    error InvalidBeneficiary();
    error Soulbound();
    error BadPagination();
    error ProviderBindingConflict();
    error AssetMismatch();
    error ProviderMismatch();
}
