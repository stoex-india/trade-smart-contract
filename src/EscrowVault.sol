// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title EscrowVault
/// @notice Logical escrow over asset micrograms scoped by (assetId, providerId).
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {StoexTypes} from "./libraries/StoexTypes.sol";
import {IAssetLedger} from "./interfaces/IAssetLedger.sol";

contract EscrowVault is Initializable, StoexDeployerAdminUpgradeable, UUPSUpgradeable {
    uint8 public version;

    IAssetLedger public assetLedger;
    address public tradeManager;

    struct EscrowLock {
        address user;
        bytes32 assetId;
        bytes32 providerId;
        uint256 amountUg;
        StoexTypes.EscrowReason reasonType;
        uint256 lockedAt;
        bool released;
    }

    mapping(uint256 => EscrowLock) private _locks;
    mapping(address => mapping(bytes32 => mapping(bytes32 => uint256))) private _lockedTotal;

    event TokensLocked(
        uint256 indexed requestId, address indexed user, bytes32 indexed assetId, bytes32 providerId, uint256 amountUg, StoexTypes.EscrowReason reason
    );
    event TokensUnlocked(uint256 indexed requestId, address indexed user, uint256 amountUg);
    event EscrowReleased(uint256 indexed requestId, address indexed user, uint256 amountUg, address destination);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployer_, address assetLedger_) external initializer {
        if (deployer_ == address(0) || assetLedger_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);
        assetLedger = IAssetLedger(assetLedger_);
        version = 2;
    }

    function setTradeManager(address tradeManager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tradeManager_ == address(0)) revert ZeroAddress();
        if (tradeManager != address(0)) revert AlreadySet();
        tradeManager = tradeManager_;
    }

    modifier onlyTradeManager() {
        _onlyTradeManager();
        _;
    }

    function _onlyTradeManager() private view {
        if (msg.sender != tradeManager) revert NotTradeManager();
    }

    function lockTokens(
        address wallet,
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        StoexTypes.EscrowReason reason,
        uint256 requestId
    ) external onlyTradeManager {
        if (_locks[requestId].user != address(0)) revert LockExists();
        uint256 available = getAvailableBalance(wallet, assetId, providerId);
        if (amountUg > available) revert ExceedsAvailable();

        _locks[requestId] = EscrowLock({
            user: wallet,
            assetId: assetId,
            providerId: providerId,
            amountUg: amountUg,
            reasonType: reason,
            lockedAt: block.timestamp,
            released: false
        });
        _lockedTotal[wallet][assetId][providerId] += amountUg;

        emit TokensLocked(requestId, wallet, assetId, providerId, amountUg, reason);
    }

    function unlockTokens(uint256 requestId) external onlyTradeManager {
        EscrowLock storage L = _locks[requestId];
        if (L.user == address(0)) revert NoLock();
        if (L.released) revert AlreadyReleased();

        L.released = true;
        _lockedTotal[L.user][L.assetId][L.providerId] -= L.amountUg;

        emit TokensUnlocked(requestId, L.user, L.amountUg);
    }

    function releaseEscrow(uint256 requestId, address destination) external onlyTradeManager {
        EscrowLock storage L = _locks[requestId];
        if (L.user == address(0)) revert NoLock();
        if (L.released) revert AlreadyReleased();
        if (destination == address(0)) revert ZeroAddress();

        L.released = true;
        _lockedTotal[L.user][L.assetId][L.providerId] -= L.amountUg;

        emit EscrowReleased(requestId, L.user, L.amountUg, destination);
    }

    function getLockedAmount(address wallet, bytes32 assetId, bytes32 providerId) external view returns (uint256) {
        return _lockedTotal[wallet][assetId][providerId];
    }

    function getAvailableBalance(address wallet, bytes32 assetId, bytes32 providerId) public view returns (uint256) {
        uint256 bal = assetLedger.userHolding(wallet, assetId, providerId);
        uint256 locked = _lockedTotal[wallet][assetId][providerId];
        return bal > locked ? bal - locked : 0;
    }

    function getEscrowDetails(uint256 requestId)
        external
        view
        returns (
            address user,
            bytes32 assetId,
            bytes32 providerId,
            uint256 amountUg,
            StoexTypes.EscrowReason reasonType,
            uint256 lockedAt,
            bool released
        )
    {
        EscrowLock storage L = _locks[requestId];
        return (L.user, L.assetId, L.providerId, L.amountUg, L.reasonType, L.lockedAt, L.released);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[47] private __gap;

    error ZeroAddress();
    error AlreadySet();
    error NotTradeManager();
    error LockExists();
    error ExceedsAvailable();
    error NoLock();
    error AlreadyReleased();
}
