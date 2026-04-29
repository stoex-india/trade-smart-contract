// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — EscrowVault
/// @notice **Logical escrow** over gold grams (not an ERC-20): tracks per-request locks so users cannot double-spend the same grams while sell/redeem requests are pending.
/// @dev Only the `TradeManager` proxy address may `lockTokens` / `unlockTokens` / `releaseEscrow` (set once via `setTradeManager`).
/// Invariant: sum of active locks per wallet ≤ `GoldNFT.userHolding(wallet)`. `getAvailableBalance` = holding minus locked.
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {StoexTypes} from "./libraries/StoexTypes.sol";
import {IGoldNFT} from "./interfaces/IGoldNFT.sol";

contract EscrowVault is Initializable, StoexDeployerAdminUpgradeable, UUPSUpgradeable {
    uint8 public version;

    IGoldNFT public goldNFT;
    address public tradeManager;

    struct EscrowLock {
        address user;
        uint256 grams;
        StoexTypes.EscrowReason reasonType;
        uint256 lockedAt;
        bool released;
    }

    mapping(uint256 => EscrowLock) private _locks;
    mapping(address => uint256) private _lockedTotal;

    event TokensLocked(uint256 indexed requestId, address indexed user, uint256 grams, StoexTypes.EscrowReason reason);
    event TokensUnlocked(uint256 indexed requestId, address indexed user, uint256 grams);
    event EscrowReleased(uint256 indexed requestId, address indexed user, uint256 grams, address destination);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployer_, address goldNFT_) external initializer {
        if (deployer_ == address(0) || goldNFT_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);
        goldNFT = IGoldNFT(goldNFT_);
        version = 1;
    }

    /// @dev One-time wire after TradeManager proxy is known.
    function setTradeManager(address tradeManager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tradeManager_ == address(0)) revert ZeroAddress();
        if (tradeManager != address(0)) revert AlreadySet();
        tradeManager = tradeManager_;
    }

    modifier onlyTradeManager() {
        if (msg.sender != tradeManager) revert NotTradeManager();
        _;
    }

    function lockTokens(address wallet, uint256 grams, StoexTypes.EscrowReason reason, uint256 requestId)
        external
        onlyTradeManager
    {
        if (_locks[requestId].user != address(0)) revert LockExists();
        uint256 available = getAvailableBalance(wallet);
        if (grams > available) revert ExceedsAvailable();

        _locks[requestId] = EscrowLock({
            user: wallet,
            grams: grams,
            reasonType: reason,
            lockedAt: block.timestamp,
            released: false
        });
        _lockedTotal[wallet] += grams;

        emit TokensLocked(requestId, wallet, grams, reason);
    }

    function unlockTokens(uint256 requestId) external onlyTradeManager {
        EscrowLock storage L = _locks[requestId];
        if (L.user == address(0)) revert NoLock();
        if (L.released) revert AlreadyReleased();

        L.released = true;
        _lockedTotal[L.user] -= L.grams;

        emit TokensUnlocked(requestId, L.user, L.grams);
    }

    function releaseEscrow(uint256 requestId, address destination) external onlyTradeManager {
        EscrowLock storage L = _locks[requestId];
        if (L.user == address(0)) revert NoLock();
        if (L.released) revert AlreadyReleased();
        if (destination == address(0)) revert ZeroAddress();

        L.released = true;
        _lockedTotal[L.user] -= L.grams;

        emit EscrowReleased(requestId, L.user, L.grams, destination);
    }

    function getLockedAmount(address wallet) external view returns (uint256) {
        return _lockedTotal[wallet];
    }

    function getAvailableBalance(address wallet) public view returns (uint256) {
        uint256 bal = goldNFT.userHolding(wallet);
        uint256 locked = _lockedTotal[wallet];
        return bal > locked ? bal - locked : 0;
    }

    function getEscrowDetails(uint256 requestId)
        external
        view
        returns (address user, uint256 grams, StoexTypes.EscrowReason reasonType, uint256 lockedAt, bool released)
    {
        EscrowLock storage L = _locks[requestId];
        return (L.user, L.grams, L.reasonType, L.lockedAt, L.released);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[49] private __gap;

    error ZeroAddress();
    error AlreadySet();
    error NotTradeManager();
    error LockExists();
    error ExceedsAvailable();
    error NoLock();
    error AlreadyReleased();
}
