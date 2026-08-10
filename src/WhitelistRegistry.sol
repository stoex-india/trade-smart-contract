// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — WhitelistRegistry
/// @notice On-chain **KYC / wallet / compliance** state. `isEligible` is the single gate used by `AssetLedger` and user-facing `TradeManager` flows.
/// @dev UUPS upgradeable. Gasless `*For` entrypoints are Tresori-relayer gated (explicit wallet; not ERC-2771 suffix).
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {StoexRelayerGate} from "./base/StoexRelayerGate.sol";

import {StoexTypes} from "./libraries/StoexTypes.sol";
import {StoexRoles} from "./libraries/StoexRoles.sol";
import {IWhitelistRegistry} from "./interfaces/IWhitelistRegistry.sol";
import {ITradeManagerOnboarding} from "./interfaces/ITradeManagerOnboarding.sol";

contract WhitelistRegistry is
    Initializable,
    StoexDeployerAdminUpgradeable,
    UUPSUpgradeable,
    StoexRelayerGate,
    IWhitelistRegistry
{
    uint8 public version;
    address private _trustedForwarderValue;
    ITradeManagerOnboarding public tradeManager;

    mapping(address => StoexTypes.UserProfile) private _profiles;
    mapping(address => bool) private _registered;
    /// @dev Enforces one active wallet per off-chain userId (audit #05).
    mapping(bytes32 => address) private _walletByUserId;

    uint256 public nextWalletChangeId;
    struct WalletChangeRequest {
        address oldWallet;
        address newWallet;
        bool adminOk;
        bool trusteeOk; // legacy field retained for storage layout; unused in V1
        bool processed;
    }
    mapping(uint256 => WalletChangeRequest) public walletChangeRequests;

    event UserRegistered(address indexed wallet, bytes32 userId);
    event KYCStatusChanged(address indexed wallet, StoexTypes.KYCStatus oldStatus, StoexTypes.KYCStatus newStatus);
    event WalletStatusChanged(address indexed wallet, StoexTypes.WalletStatus oldStatus, StoexTypes.WalletStatus newStatus);
    event UserStatusChanged(address indexed wallet, StoexTypes.UserStatus oldStatus, StoexTypes.UserStatus newStatus);
    event WalletChangeRequested(uint256 indexed requestId, address oldWallet, address newWallet);
    event WalletChangeApproved(uint256 indexed requestId, address newWallet);
    event RiskLevelChanged(address indexed wallet, StoexTypes.RiskLevel oldLevel, StoexTypes.RiskLevel newLevel, bytes32 caseRef);
    event TradeManagerUpdated(address indexed previous, address indexed current);
    event TrustedForwarderUpdated(address indexed previous, address indexed current);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address deployer_, address trustedForwarder_) external initializer {
        if (deployer_ == address(0) || trustedForwarder_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);
        _trustedForwarderValue = trustedForwarder_;
        version = 4;
    }

    function setTrustedForwarder(address trustedForwarder_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (trustedForwarder_ == address(0)) revert ZeroAddress();
        address prev = _trustedForwarderValue;
        _trustedForwarderValue = trustedForwarder_;
        emit TrustedForwarderUpdated(prev, trustedForwarder_);
    }

    function trustedForwarder() public view override returns (address) {
        return _trustedForwarderValue;
    }

    function setTradeManager(address tradeManager_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tradeManager_ == address(0)) revert ZeroAddress();
        if (tradeManager_.code.length == 0) revert NotContract();
        address prev = address(tradeManager);
        tradeManager = ITradeManagerOnboarding(tradeManager_);
        emit TradeManagerUpdated(prev, tradeManager_);
    }

    /// @notice Gasless self-registration via Tresori relayer. `wallet` is the investor MPC address (`fromAddress`).
    function registerUserFor(address wallet, bytes32 userId, string calldata kycRef) external onlyTrustedForwarder {
        _registerUser(wallet, userId, kycRef);
    }

    /// @notice Admin back-office registration for any wallet (admin panel).
    function adminRegisterUser(bytes32 userId, address wallet, string calldata kycRef)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _registerUser(wallet, userId, kycRef);
    }

    function _registerUser(address wallet, bytes32 userId, string calldata kycRef) private {
        if (wallet == address(0)) revert ZeroAddress();
        if (userId == bytes32(0)) revert ZeroUserId();
        if (_registered[wallet]) revert AlreadyRegistered();
        if (_walletByUserId[userId] != address(0)) revert UserIdAlreadyUsed();
        if (address(tradeManager) == address(0)) revert TradeManagerNotSet();

        _registered[wallet] = true;
        _walletByUserId[userId] = wallet;
        _profiles[wallet] = StoexTypes.UserProfile({
            userId: userId,
            wallet: wallet,
            kycStatus: StoexTypes.KYCStatus.Pending,
            walletStatus: StoexTypes.WalletStatus.Whitelisted,
            userStatus: StoexTypes.UserStatus.Active,
            riskLevel: StoexTypes.RiskLevel.Low,
            kycRef: kycRef,
            registeredAt: block.timestamp
        });

        if (!hasRole(StoexRoles.USER_ROLE, wallet)) {
            _grantRole(StoexRoles.USER_ROLE, wallet);
        }
        tradeManager.grantUserRoleFromRegistry(wallet);

        emit UserRegistered(wallet, userId);
    }

    function verifyKYCFor(address user) external onlyTrustedForwarder {
        _verifyKYC(user);
    }

    function _verifyKYC(address user) private {
        if (!_registered[user]) revert NotRegistered();
        StoexTypes.UserProfile storage p = _profiles[user];
        if (p.kycStatus != StoexTypes.KYCStatus.Pending) revert KycNotPending();
        StoexTypes.KYCStatus old_ = p.kycStatus;
        p.kycStatus = StoexTypes.KYCStatus.Verified;
        emit KYCStatusChanged(user, old_, p.kycStatus);
    }

    function rejectKYC(address wallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StoexTypes.UserProfile storage p = _profiles[wallet];
        if (!_registered[wallet]) revert NotRegistered();
        StoexTypes.KYCStatus old_ = p.kycStatus;
        p.kycStatus = StoexTypes.KYCStatus.Rejected;
        emit KYCStatusChanged(wallet, old_, p.kycStatus);
    }

    function whitelistWallet(address wallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StoexTypes.UserProfile storage p = _profiles[wallet];
        if (!_registered[wallet]) revert NotRegistered();
        StoexTypes.WalletStatus old_ = p.walletStatus;
        p.walletStatus = StoexTypes.WalletStatus.Whitelisted;
        emit WalletStatusChanged(wallet, old_, p.walletStatus);
    }

    function requestWalletChangeFor(address wallet, address oldWallet, address newWallet)
        external
        onlyTrustedForwarder
    {
        if (!hasRole(StoexRoles.USER_ROLE, wallet)) revert NotWalletOwner();
        _requestWalletChange(wallet, oldWallet, newWallet);
    }

    function requestWalletChange(address oldWallet, address newWallet) external onlyRole(StoexRoles.USER_ROLE) {
        _requestWalletChange(msg.sender, oldWallet, newWallet);
    }

    function _requestWalletChange(address wallet, address oldWallet, address newWallet) private {
        if (newWallet == address(0)) revert ZeroAddress();
        if (wallet != oldWallet) revert NotWalletOwner();
        if (!_registered[oldWallet]) revert NotRegistered();
        uint256 id = ++nextWalletChangeId;
        walletChangeRequests[id] =
            WalletChangeRequest({oldWallet: oldWallet, newWallet: newWallet, adminOk: false, trusteeOk: false, processed: false});
        emit WalletChangeRequested(id, oldWallet, newWallet);
    }

    function approveWalletChangeFor(address actor, uint256 changeRequestId) external onlyTrustedForwarder {
        _approveWalletChange(actor, changeRequestId);
    }

    function approveWalletChange(uint256 changeRequestId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _approveWalletChange(msg.sender, changeRequestId);
    }

    function _approveWalletChange(address actor, uint256 changeRequestId) private {
        if (!hasRole(DEFAULT_ADMIN_ROLE, actor)) revert NotAdmin();
        WalletChangeRequest storage w = walletChangeRequests[changeRequestId];
        if (w.oldWallet == address(0)) revert InvalidRequest();
        if (w.processed) revert AlreadyProcessed();

        w.adminOk = true;
        _migrateWallet(w.oldWallet, w.newWallet);
        w.processed = true;
        emit WalletChangeApproved(changeRequestId, w.newWallet);
    }

    function _migrateWallet(address oldWallet, address newWallet) private {
        if (_registered[newWallet]) revert AlreadyRegistered();
        StoexTypes.UserProfile memory prof = _profiles[oldWallet];
        if (!_registered[oldWallet]) revert NotRegistered();

        delete _profiles[oldWallet];
        _registered[oldWallet] = false;

        if (hasRole(StoexRoles.USER_ROLE, oldWallet)) {
            _revokeRole(StoexRoles.USER_ROLE, oldWallet);
        }
        tradeManager.revokeUserRoleFromRegistry(oldWallet);

        prof.wallet = newWallet;
        _profiles[newWallet] = prof;
        _registered[newWallet] = true;
        _walletByUserId[prof.userId] = newWallet;

        if (!hasRole(StoexRoles.USER_ROLE, newWallet)) {
            _grantRole(StoexRoles.USER_ROLE, newWallet);
        }
        tradeManager.grantUserRoleFromRegistry(newWallet);
    }

    function walletOfUserId(bytes32 userId) external view returns (address) {
        return _walletByUserId[userId];
    }

    function suspendWallet(address wallet, bytes32 caseRef) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StoexTypes.UserProfile storage p = _profiles[wallet];
        if (!_registered[wallet]) revert NotRegistered();
        StoexTypes.WalletStatus old_ = p.walletStatus;
        p.walletStatus = StoexTypes.WalletStatus.Suspended;
        emit WalletStatusChanged(wallet, old_, p.walletStatus);
        emit RiskLevelChanged(wallet, p.riskLevel, p.riskLevel, caseRef);
    }

    function blacklistWallet(address wallet, bytes32 caseRef) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StoexTypes.UserProfile storage p = _profiles[wallet];
        if (!_registered[wallet]) revert NotRegistered();
        StoexTypes.WalletStatus old_ = p.walletStatus;
        p.walletStatus = StoexTypes.WalletStatus.Blacklisted;
        emit WalletStatusChanged(wallet, old_, p.walletStatus);
        emit RiskLevelChanged(wallet, p.riskLevel, p.riskLevel, caseRef);
    }

    function setWalletRisk(address wallet, StoexTypes.RiskLevel level, bytes32 caseRef)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        StoexTypes.UserProfile storage p = _profiles[wallet];
        if (!_registered[wallet]) revert NotRegistered();
        StoexTypes.RiskLevel old_ = p.riskLevel;
        p.riskLevel = level;
        emit RiskLevelChanged(wallet, old_, level, caseRef);
    }

    function setUserBlocked(address wallet, bool blocked) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StoexTypes.UserProfile storage p = _profiles[wallet];
        if (!_registered[wallet]) revert NotRegistered();
        StoexTypes.UserStatus old_ = p.userStatus;
        p.userStatus = blocked ? StoexTypes.UserStatus.Blocked : StoexTypes.UserStatus.Active;
        emit UserStatusChanged(wallet, old_, p.userStatus);
    }

    function unsuspendWallet(address wallet, bytes32 caseRef) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StoexTypes.UserProfile storage p = _profiles[wallet];
        if (!_registered[wallet]) revert NotRegistered();
        StoexTypes.WalletStatus old_ = p.walletStatus;
        p.walletStatus = StoexTypes.WalletStatus.Whitelisted;
        emit WalletStatusChanged(wallet, old_, p.walletStatus);
        emit RiskLevelChanged(wallet, p.riskLevel, p.riskLevel, caseRef);
    }

    function isEligible(address wallet) external view override returns (bool) {
        if (!_registered[wallet]) return false;
        StoexTypes.UserProfile storage p = _profiles[wallet];
        if (p.kycStatus != StoexTypes.KYCStatus.Verified) return false;
        if (p.walletStatus != StoexTypes.WalletStatus.Whitelisted) return false;
        if (p.userStatus != StoexTypes.UserStatus.Active) return false;
        if (uint256(p.riskLevel) >= uint256(StoexTypes.RiskLevel.Flagged)) return false;
        return true;
    }

    /// @inheritdoc IWhitelistRegistry
    function isEligibleForNonKycUser(address wallet) external view override returns (bool) {
        if (!_registered[wallet]) return false;
        StoexTypes.UserProfile storage p = _profiles[wallet];
        if (p.kycStatus != StoexTypes.KYCStatus.Pending) return false;
        if (p.walletStatus != StoexTypes.WalletStatus.Whitelisted) return false;
        if (p.userStatus != StoexTypes.UserStatus.Active) return false;
        if (uint256(p.riskLevel) >= uint256(StoexTypes.RiskLevel.Flagged)) return false;
        return true;
    }

    function getProfile(address wallet) external view override returns (StoexTypes.UserProfile memory) {
        return _profiles[wallet];
    }

    /// @inheritdoc IWhitelistRegistry
    function hasUserRole(address wallet) external view override returns (bool) {
        return hasRole(StoexRoles.USER_ROLE, wallet);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    error ZeroAddress();
    error ZeroUserId();
    error UserIdAlreadyUsed();
    error TradeManagerNotSet();
    error NotContract();
    error AlreadyRegistered();
    error NotRegistered();
    error NotWalletOwner();
    error InvalidRequest();
    error AlreadyProcessed();
    error KycNotPending();
    error NotAdmin();
}
