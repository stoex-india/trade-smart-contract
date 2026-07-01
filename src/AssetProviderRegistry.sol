// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AssetProviderRegistry
/// @notice Asset Provider entities, supported assets, operator wallets, and per-asset routing.
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {IAssetProviderRegistry} from "./interfaces/IAssetProviderRegistry.sol";
import {IAssetRegistry} from "./interfaces/IAssetRegistry.sol";

contract AssetProviderRegistry is Initializable, StoexDeployerAdminUpgradeable, UUPSUpgradeable, IAssetProviderRegistry {
    uint8 public version;

    IAssetRegistry public assetRegistry;

    struct ProviderConfig {
        bool active;
        bool registered;
        string name;
    }

    struct AssetRouting {
        address sellPayout;
        address redeemSink;
    }

    mapping(bytes32 providerId => ProviderConfig) private _providers;
    mapping(bytes32 providerId => mapping(bytes32 assetId => bool)) private _supported;
    mapping(bytes32 providerId => mapping(bytes32 assetId => AssetRouting)) private _routing;
    mapping(address operator => bytes32 providerId) private _operatorToProvider;
    mapping(bytes32 providerId => address[]) private _operators;

    event ProviderRegistered(bytes32 indexed providerId, string name);
    event ProviderNameUpdated(bytes32 indexed providerId, string name);
    event ProviderActiveChanged(bytes32 indexed providerId, bool active);
    event ProviderAssetSet(bytes32 indexed providerId, bytes32 indexed assetId, bool supported);
    event AssetRoutingSet(bytes32 indexed providerId, bytes32 indexed assetId, address sellPayout, address redeemSink);
    event OperatorAdded(bytes32 indexed providerId, address indexed operator);
    event OperatorRemoved(bytes32 indexed providerId, address indexed operator);
    event AssetRegistryUpdated(address registry);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployer_, address assetRegistry_) external initializer {
        if (deployer_ == address(0) || assetRegistry_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);
        assetRegistry = IAssetRegistry(assetRegistry_);
        version = 1;
    }

    function setAssetRegistry(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (registry == address(0)) revert ZeroAddress();
        assetRegistry = IAssetRegistry(registry);
        emit AssetRegistryUpdated(registry);
    }

    function registerProvider(bytes32 providerId, string calldata name) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (providerId == bytes32(0)) revert ZeroProviderId();
        if (bytes(name).length == 0) revert EmptyName();
        if (_providers[providerId].registered) revert ProviderExists();
        _providers[providerId] = ProviderConfig({active: true, registered: true, name: name});
        emit ProviderRegistered(providerId, name);
    }

    function setProviderActive(bytes32 providerId, bool active) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_providers[providerId].registered) revert UnknownProvider();
        _providers[providerId].active = active;
        emit ProviderActiveChanged(providerId, active);
    }

    function updateProviderName(bytes32 providerId, string calldata name) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_providers[providerId].registered) revert UnknownProvider();
        if (bytes(name).length == 0) revert EmptyName();
        _providers[providerId].name = name;
        emit ProviderNameUpdated(providerId, name);
    }

    function setProviderAsset(bytes32 providerId, bytes32 assetId, bool supported) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_providers[providerId].registered) revert UnknownProvider();
        if (!assetRegistry.isActive(assetId)) revert AssetNotActive();
        _supported[providerId][assetId] = supported;
        emit ProviderAssetSet(providerId, assetId, supported);
    }

    function setAssetRouting(bytes32 providerId, bytes32 assetId, address sellPayout, address redeemSink)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (!_providers[providerId].registered) revert UnknownProvider();
        if (!_supported[providerId][assetId]) revert AssetNotSupported();
        if (sellPayout == address(0) || redeemSink == address(0)) revert ZeroAddress();
        _routing[providerId][assetId] = AssetRouting({sellPayout: sellPayout, redeemSink: redeemSink});
        emit AssetRoutingSet(providerId, assetId, sellPayout, redeemSink);
    }

    function addProviderOperator(bytes32 providerId, address wallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_providers[providerId].registered) revert UnknownProvider();
        if (wallet == address(0)) revert ZeroAddress();
        if (_operatorToProvider[wallet] != bytes32(0)) revert OperatorAlreadyAssigned();
        _operatorToProvider[wallet] = providerId;
        _operators[providerId].push(wallet);
        emit OperatorAdded(providerId, wallet);
    }

    function removeProviderOperator(bytes32 providerId, address wallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_operatorToProvider[wallet] != providerId) revert NotOperator();
        delete _operatorToProvider[wallet];
        address[] storage ops = _operators[providerId];
        for (uint256 i = 0; i < ops.length; i++) {
            if (ops[i] == wallet) {
                ops[i] = ops[ops.length - 1];
                ops.pop();
                break;
            }
        }
        emit OperatorRemoved(providerId, wallet);
    }

    function isProviderActive(bytes32 providerId) external view override returns (bool) {
        ProviderConfig storage p = _providers[providerId];
        return p.registered && p.active;
    }

    function providerSupportsAsset(bytes32 providerId, bytes32 assetId) external view override returns (bool) {
        return _supported[providerId][assetId];
    }

    function isOperator(bytes32 providerId, address wallet) external view override returns (bool) {
        return _operatorToProvider[wallet] == providerId;
    }

    function getSellPayout(bytes32 providerId, bytes32 assetId) external view override returns (address) {
        address payout = _routing[providerId][assetId].sellPayout;
        if (payout == address(0)) revert RoutingNotSet();
        return payout;
    }

    function getRedeemSink(bytes32 providerId, bytes32 assetId) external view override returns (address) {
        address sink = _routing[providerId][assetId].redeemSink;
        if (sink == address(0)) revert RoutingNotSet();
        return sink;
    }

    function getProvider(bytes32 providerId) external view returns (bool active, string memory name) {
        ProviderConfig storage p = _providers[providerId];
        return (p.active, p.name);
    }

    function getOperators(bytes32 providerId) external view returns (address[] memory) {
        return _operators[providerId];
    }

    function operatorProvider(address wallet) external view returns (bytes32) {
        return _operatorToProvider[wallet];
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[44] private __gap;

    error ZeroAddress();
    error ZeroProviderId();
    error EmptyName();
    error ProviderExists();
    error UnknownProvider();
    error AssetNotActive();
    error AssetNotSupported();
    error OperatorAlreadyAssigned();
    error NotOperator();
    error RoutingNotSet();
}
