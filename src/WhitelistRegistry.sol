// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — WhitelistRegistry
/// @notice On-chain **KYC / wallet / compliance** state. `isEligible` is the single gate used by `GoldNFT` and user-facing `TradeManager` flows.
/// @dev UUPS upgradeable. Important roles (same `AccessControl` pattern as PRD):
/// - `DEFAULT_ADMIN_ROLE`: onboard users, KYC, wallet risk, suspend/blacklist, grant `USER_ROLE` for wallet-change requests.
/// - `USER_ROLE`: investor may `requestWalletChange` for their own wallet.
/// - `AT_ROLE`: co-approve wallet migration with admin; `unsuspendWallet` override.
/// Wallet migration copies `UserProfile` to the new address; old address is unregistered.
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

import {StoexTypes} from "./libraries/StoexTypes.sol";
import {StoexRoles} from "./libraries/StoexRoles.sol";
import {IWhitelistRegistry} from "./interfaces/IWhitelistRegistry.sol";

contract WhitelistRegistry is
    Initializable,
    StoexDeployerAdminUpgradeable,
    ERC2771ContextUpgradeable,
    UUPSUpgradeable,
    IWhitelistRegistry
{
    uint8 public version;
    address private _trustedForwarderValue;

    mapping(address => StoexTypes.UserProfile) private _profiles;
    mapping(address => bool) private _registered;

    uint256 public nextWalletChangeId;
    struct WalletChangeRequest {
        address oldWallet;
        address newWallet;
        bool adminOk;
        bool trusteeOk;
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() ERC2771ContextUpgradeable(address(0)) {
        _disableInitializers();
    }

    function initialize(address deployer_, address trustedForwarder_) external initializer {
        if (deployer_ == address(0) || trustedForwarder_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);
        _trustedForwarderValue = trustedForwarder_;
        version = 1;
    }

    /// @notice Updates trusted ERC-2771 forwarder for gasless registry operations.
    function setTrustedForwarder(address trustedForwarder_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (trustedForwarder_ == address(0)) revert ZeroAddress();
        _trustedForwarderValue = trustedForwarder_;
    }

    function trustedForwarder() public view override returns (address) {
        return _trustedForwarderValue;
    }

    function registerUser(bytes32 userId, address wallet, string calldata kycRef) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (wallet == address(0)) revert ZeroAddress();
        if (_registered[wallet]) revert AlreadyRegistered();
        _registered[wallet] = true;
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
        emit UserRegistered(wallet, userId);
    }

    function verifyKYC(address wallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StoexTypes.UserProfile storage p = _profiles[wallet];
        if (!_registered[wallet]) revert NotRegistered();
        StoexTypes.KYCStatus old_ = p.kycStatus;
        p.kycStatus = StoexTypes.KYCStatus.Verified;
        emit KYCStatusChanged(wallet, old_, p.kycStatus);
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

    function requestWalletChange(address oldWallet, address newWallet) external onlyRole(StoexRoles.USER_ROLE) {
        if (newWallet == address(0)) revert ZeroAddress();
        if (_msgSender() != oldWallet) revert NotWalletOwner();
        if (!_registered[oldWallet]) revert NotRegistered();
        uint256 id = ++nextWalletChangeId;
        walletChangeRequests[id] = WalletChangeRequest({oldWallet: oldWallet, newWallet: newWallet, adminOk: false, trusteeOk: false, processed: false});
        emit WalletChangeRequested(id, oldWallet, newWallet);
    }

    /// @notice Asset Trustee and Default Admin must both call this (in any order) before migration runs.
    function approveWalletChange(uint256 changeRequestId) external {
        WalletChangeRequest storage w = walletChangeRequests[changeRequestId];
        if (w.oldWallet == address(0)) revert InvalidRequest();
        if (w.processed) revert AlreadyProcessed();

        if (hasRole(StoexRoles.AT_ROLE, _msgSender())) w.trusteeOk = true;
        if (hasRole(DEFAULT_ADMIN_ROLE, _msgSender())) w.adminOk = true;

        if (w.adminOk && w.trusteeOk) {
            _migrateWallet(w.oldWallet, w.newWallet);
            w.processed = true;
            emit WalletChangeApproved(changeRequestId, w.newWallet);
        }
    }

    function _migrateWallet(address oldWallet, address newWallet) private {
        if (_registered[newWallet]) revert AlreadyRegistered();
        StoexTypes.UserProfile memory prof = _profiles[oldWallet];
        if (!_registered[oldWallet]) revert NotRegistered();

        delete _profiles[oldWallet];
        _registered[oldWallet] = false;

        prof.wallet = newWallet;
        _profiles[newWallet] = prof;
        _registered[newWallet] = true;
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

    function setWalletRisk(address wallet, StoexTypes.RiskLevel level, bytes32 caseRef) external onlyRole(DEFAULT_ADMIN_ROLE) {
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

    function unsuspendWallet(address wallet, bytes32 caseRef) external onlyRole(StoexRoles.AT_ROLE) {
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

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function _contextSuffixLength()
        internal
        view
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }


    function _msgSender() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }

    error ZeroAddress();
    error AlreadyRegistered();
    error NotRegistered();
    error NotWalletOwner();
    error InvalidRequest();
    error AlreadyProcessed();
}
