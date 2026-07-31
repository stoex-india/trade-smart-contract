// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TradeManager
/// @notice Central orchestrator for multi-asset, multi-provider trade requests (V1).
/// @dev Buy auto-executes. Sell/Redeem escrow then admin `executeRequest(requestId, settlementRef)`.
///      No mint/burn. No multi-party approvals — only Admin and User roles on the trade path.
import {StoexRelayerGate} from "./base/StoexRelayerGate.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {StoexTypes} from "./libraries/StoexTypes.sol";
import {StoexRoles} from "./libraries/StoexRoles.sol";
import {TradeManagerLib} from "./libraries/TradeManagerLib.sol";
import {IWhitelistRegistry} from "./interfaces/IWhitelistRegistry.sol";
import {IGovernanceConfig} from "./interfaces/IGovernanceConfig.sol";
import {IAssetLedger} from "./interfaces/IAssetLedger.sol";
import {IAssetRegistry} from "./interfaces/IAssetRegistry.sol";
import {IAssetProviderRegistry} from "./interfaces/IAssetProviderRegistry.sol";
import {IEscrowVault} from "./interfaces/IEscrowVault.sol";
import {ITimelockController} from "./interfaces/ITimelockController.sol";

contract TradeManager is
    Initializable,
    StoexDeployerAdminUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    StoexRelayerGate
{
    uint8 public version;

    IGovernanceConfig public governance;
    IWhitelistRegistry public whitelistRegistry;
    IAssetLedger public assetLedger;
    IAssetRegistry public assetRegistry;
    IAssetProviderRegistry public assetProviderRegistry;
    IEscrowVault public escrowVault;
    ITimelockController public timelockController;

    address private _trustedForwarderValue;

    uint256 public nextRequestId;

    TradeManagerLib.DayCaps private _dayCaps;

    mapping(uint256 => StoexTypes.TradeRequest) private _requests;
    // Legacy co-sign / step-approval slots retained for UUPS layout.
    mapping(uint256 => mapping(uint256 => bool)) private _stepApproved;
    mapping(uint256 => uint256) private _coSignNonceLegacy;
    mapping(address => uint256) private _nonKycFiatPurchased;

    event RequestCreated(
        uint256 indexed requestId,
        bytes32 indexed assetId,
        bytes32 indexed providerId,
        StoexTypes.RequestType requestType,
        address initiator,
        uint256 amountUg,
        uint256 fiatValue
    );
    event RequestRejected(uint256 indexed requestId, address rejector, string reason);
    event RequestExecuted(uint256 indexed requestId, StoexTypes.RequestType requestType);
    event RequestCancelled(uint256 indexed requestId);
    event RequestExpired(uint256 indexed requestId);
    event SettlementRefSet(uint256 indexed requestId, bytes32 settlementRefId);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address deployer_,
        address governance_,
        address whitelistRegistry_,
        address assetLedger_,
        address escrowVault_,
        address timelockController_,
        address assetRegistry_,
        address assetProviderRegistry_,
        address trustedForwarder_
    ) external initializer {
        if (
            deployer_ == address(0) || governance_ == address(0) || whitelistRegistry_ == address(0)
                || assetLedger_ == address(0) || escrowVault_ == address(0) || timelockController_ == address(0)
                || assetRegistry_ == address(0) || assetProviderRegistry_ == address(0)
                || trustedForwarder_ == address(0)
        ) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);

        governance = IGovernanceConfig(governance_);
        whitelistRegistry = IWhitelistRegistry(whitelistRegistry_);
        assetLedger = IAssetLedger(assetLedger_);
        escrowVault = IEscrowVault(escrowVault_);
        timelockController = ITimelockController(timelockController_);
        assetRegistry = IAssetRegistry(assetRegistry_);
        assetProviderRegistry = IAssetProviderRegistry(assetProviderRegistry_);
        _trustedForwarderValue = trustedForwarder_;

        version = 3;
    }

    function setTrustedForwarder(address trustedForwarder_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (trustedForwarder_ == address(0)) revert ZeroAddress();
        _trustedForwarderValue = trustedForwarder_;
    }

    function trustedForwarder() public view override returns (address) {
        return _trustedForwarderValue;
    }

    function grantUserRoleFromRegistry(address user) external {
        if (msg.sender != address(whitelistRegistry)) revert NotWhitelistRegistry();
        if (user == address(0)) revert ZeroAddress();
        _grantRole(StoexRoles.USER_ROLE, user);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Instant buy. `payment_ref` should be a client-side SHA-256 hash of the off-chain payment ref.
    function createBuyRequestFor(
        address user,
        bytes32 assetId,
        bytes32 providerId,
        uint256 weightUg,
        uint256 fiat_value,
        bytes32 payment_ref,
        bytes32 txDetailsHash
    ) external onlyTrustedForwarder whenNotPaused nonReentrant returns (uint256 requestId) {
        _requireUserRole(user);
        return _createBuyRequest(user, assetId, providerId, weightUg, fiat_value, payment_ref, txDetailsHash);
    }

    function _createBuyRequest(
        address user,
        bytes32 assetId,
        bytes32 providerId,
        uint256 weightUg,
        uint256 fiat_value,
        bytes32 payment_ref,
        bytes32 txDetailsHash
    ) private returns (uint256 requestId) {
        _validateAssetProvider(assetId, providerId);
        _checkBuyAmount(assetId, weightUg);
        if (fiat_value == 0) revert ZeroFiatValue();
        _requireBuyProviderBinding(user, assetId, providerId);

        if (whitelistRegistry.isEligible(user)) {
            _checkBuyCap(assetId, weightUg);
        } else if (whitelistRegistry.isEligibleForNonKycUser(user)) {
            _checkNonKycFiatCap(user, fiat_value);
        } else {
            revert NotEligible();
        }

        requestId = ++nextRequestId;
        _finalizeBuy(requestId, user, assetId, providerId, weightUg, fiat_value, payment_ref, txDetailsHash);
    }

    /// @notice Create sell — settlement ref is supplied later by admin at execute.
    function createSellRequestFor(address user, bytes32 assetId, bytes32 providerId, uint256 amountUg)
        external
        onlyTrustedForwarder
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        _requireUserRole(user);
        return _createSellRequest(user, assetId, providerId, amountUg);
    }

    function _createSellRequest(address user, bytes32 assetId, bytes32 providerId, uint256 amountUg)
        private
        returns (uint256 requestId)
    {
        _validateAssetProvider(assetId, providerId);
        _requireEligible(user);
        _requireNotTimelocked(user, assetId);
        _requireUserProviderBinding(user, assetId, providerId);
        _checkAmountUg(amountUg);
        _checkSellCap(assetId, amountUg);

        requestId = ++nextRequestId;
        escrowVault.lockTokens(user, assetId, providerId, amountUg, StoexTypes.EscrowReason.Sell, requestId);
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        TradeManagerLib.initPendingRequest(
            _requests[requestId],
            assetId,
            providerId,
            StoexTypes.RequestType.Sell,
            user,
            user,
            amountUg,
            bytes32(0),
            bytes32(0),
            "",
            exp,
            TradeManagerLib.emptyLot(),
            true
        );

        emit RequestCreated(requestId, assetId, providerId, StoexTypes.RequestType.Sell, user, amountUg, 0);
    }

    /// @notice Create redeem — delivery/settlement ref is supplied later by admin at execute.
    function createRedeemRequestFor(address user, bytes32 assetId, bytes32 providerId, uint256 amountUg)
        external
        onlyTrustedForwarder
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        _requireUserRole(user);
        return _createRedeemRequest(user, assetId, providerId, amountUg);
    }

    function _createRedeemRequest(address user, bytes32 assetId, bytes32 providerId, uint256 amountUg)
        private
        returns (uint256 requestId)
    {
        _validateAssetProvider(assetId, providerId);
        _requireEligible(user);
        _requireNotTimelocked(user, assetId);
        _requireUserProviderBinding(user, assetId, providerId);
        if (amountUg < governance.minRedeemAmountUg()) revert BelowMinRedeem();
        _checkAmountUg(amountUg);

        requestId = ++nextRequestId;
        escrowVault.lockTokens(user, assetId, providerId, amountUg, StoexTypes.EscrowReason.Redeem, requestId);
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        TradeManagerLib.initPendingRequest(
            _requests[requestId],
            assetId,
            providerId,
            StoexTypes.RequestType.Redeem,
            user,
            user,
            amountUg,
            bytes32(0),
            bytes32(0),
            "",
            exp,
            TradeManagerLib.emptyLot(),
            true
        );

        emit RequestCreated(requestId, assetId, providerId, StoexTypes.RequestType.Redeem, user, amountUg, 0);
    }

    /// @notice Admin rejects a pending sell/redeem (unlocks escrow).
    function rejectRequest(uint256 requestId, string calldata reason_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        nonReentrant
    {
        StoexTypes.TradeRequest storage r = _requests[requestId];
        _requirePending(r);
        if (r.escrowLocked) {
            escrowVault.unlockTokens(requestId);
        }
        r.escrowLocked = false;
        r.status = StoexTypes.RequestStatus.Rejected;
        emit RequestRejected(requestId, msg.sender, reason_);
    }

    function cancelRequestFor(address initiator, uint256 requestId)
        external
        onlyTrustedForwarder
        whenNotPaused
        nonReentrant
    {
        _cancelRequest(initiator, requestId);
    }

    function _cancelRequest(address initiator, uint256 requestId) private {
        StoexTypes.TradeRequest storage r = _requests[requestId];
        if (r.initiator != initiator) revert NotInitiator();
        _requirePending(r);
        if (r.escrowLocked) {
            escrowVault.unlockTokens(requestId);
        }
        r.escrowLocked = false;
        r.status = StoexTypes.RequestStatus.Cancelled;
        emit RequestCancelled(requestId);
    }

    function expireRequest(uint256 requestId) external nonReentrant {
        StoexTypes.TradeRequest storage r = _requests[requestId];
        if (block.timestamp <= r.expiresAt) revert NotExpired();
        if (
            r.status == StoexTypes.RequestStatus.Executed || r.status == StoexTypes.RequestStatus.Rejected
                || r.status == StoexTypes.RequestStatus.Cancelled || r.status == StoexTypes.RequestStatus.Expired
        ) revert BadStatus();

        if (r.escrowLocked) {
            escrowVault.unlockTokens(requestId);
        }
        r.escrowLocked = false;
        r.status = StoexTypes.RequestStatus.Expired;
        emit RequestExpired(requestId);
    }

    /// @notice Admin executes sell/redeem. `settlementRefId` is a client-side SHA-256 hash (payout / delivery).
    function executeRequest(uint256 requestId, bytes32 settlementRefId)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        whenNotPaused
        nonReentrant
    {
        StoexTypes.TradeRequest storage r = _requests[requestId];
        if (r.requestType == StoexTypes.RequestType.Buy) revert BuyUsesAutoExecution();
        if (r.requestType != StoexTypes.RequestType.Sell && r.requestType != StoexTypes.RequestType.Redeem) {
            revert UnsupportedRequestType();
        }
        if (r.status != StoexTypes.RequestStatus.Proposed) revert BadStatus();
        if (block.timestamp > r.expiresAt) revert Expired();
        if (settlementRefId == bytes32(0)) revert ZeroSettlementRef();

        r.paymentRefId = settlementRefId;
        emit SettlementRefSet(requestId, settlementRefId);

        TradeManagerLib.executeTrade(
            r, requestId, _dayCaps, whitelistRegistry, governance, assetLedger, assetProviderRegistry, escrowVault
        );
        r.status = StoexTypes.RequestStatus.Executed;
        emit RequestExecuted(requestId, r.requestType);
    }

    function getRequest(uint256 requestId) external view returns (StoexTypes.TradeRequest memory) {
        return _requests[requestId];
    }

    function getRequestStatus(uint256 requestId) external view returns (StoexTypes.RequestStatus) {
        return _requests[requestId].status;
    }

    function _validateAssetProvider(bytes32 assetId, bytes32 providerId) private view {
        if (!assetRegistry.isActive(assetId)) revert InactiveAsset();
        if (!assetProviderRegistry.isProviderActive(providerId)) revert InactiveProvider();
        if (!assetProviderRegistry.providerSupportsAsset(providerId, assetId)) revert AssetNotSupported();
    }

    function _requireUserProviderBinding(address user, bytes32 assetId, bytes32 providerId) private view {
        if (assetLedger.userActiveProvider(user, assetId) != providerId) revert ProviderBindingConflict();
    }

    function _requireBuyProviderBinding(address user, bytes32 assetId, bytes32 providerId) private view {
        bytes32 active = assetLedger.userActiveProvider(user, assetId);
        if (active != bytes32(0) && active != providerId) revert ProviderBindingConflict();
    }

    function _finalizeBuy(
        uint256 requestId,
        address user,
        bytes32 assetId,
        bytes32 providerId,
        uint256 weightUg,
        uint256 fiat_value,
        bytes32 payment_ref,
        bytes32 txDetailsHash_
    ) private {
        TradeManagerLib.finalizeBuy(
            _requests[requestId],
            requestId,
            user,
            assetId,
            providerId,
            weightUg,
            fiat_value,
            payment_ref,
            txDetailsHash_,
            _dayCaps,
            _nonKycFiatPurchased,
            whitelistRegistry,
            governance,
            assetLedger
        );

        emit RequestCreated(requestId, assetId, providerId, StoexTypes.RequestType.Buy, user, weightUg, fiat_value);
        emit RequestExecuted(requestId, StoexTypes.RequestType.Buy);
    }

    function _requireEligible(address u) private view {
        if (!whitelistRegistry.isEligible(u)) revert NotEligible();
    }

    function _requireUserRole(address user) private view {
        if (!hasRole(StoexRoles.USER_ROLE, user)) revert NotUser();
    }

    function _requireNotTimelocked(address user, bytes32 assetId) private view {
        TradeManagerLib.requireNotTimelocked(user, assetId, timelockController, assetLedger);
    }

    function _checkAmountUg(uint256 amountUg) private view {
        if (amountUg == 0) revert ZeroAmount();
        if (amountUg > governance.maxAmountPerTx()) revert ExceedsMax();
    }

    function _checkBuyAmount(bytes32 assetId, uint256 weightUg) private view {
        if (weightUg == 0) revert ZeroAmount();
        if (weightUg > governance.maxAmountPerTx()) revert ExceedsMax();
        uint256 minUg = governance.minimumBuyValueInUg(assetId);
        if (minUg > 0 && weightUg < minUg) revert BelowMinBuy();
    }

    function _checkBuyCap(bytes32 assetId, uint256 amountUg) private view {
        uint256 day = block.timestamp / 1 days;
        uint256 used = _dayCaps.buyDay[assetId] == day ? _dayCaps.buyDayAmountUg[assetId] : 0;
        if (used + amountUg > governance.dailyBuyCap(assetId)) revert CapBuy();
    }

    function _checkNonKycFiatCap(address user, uint256 fiatValue_) private view {
        if (_nonKycFiatPurchased[user] + fiatValue_ > governance.nonKycMaxBuyFiatAmount()) revert CapBuyNonKyc();
    }

    function _checkSellCap(bytes32 assetId, uint256 amountUg) private view {
        uint256 day = block.timestamp / 1 days;
        uint256 used = _dayCaps.sellDay[assetId] == day ? _dayCaps.sellDayAmountUg[assetId] : 0;
        if (used + amountUg > governance.dailySellCap(assetId)) revert CapSell();
    }

    function _requirePending(StoexTypes.TradeRequest storage r) private view {
        if (
            r.status == StoexTypes.RequestStatus.Executed || r.status == StoexTypes.RequestStatus.Rejected
                || r.status == StoexTypes.RequestStatus.Cancelled || r.status == StoexTypes.RequestStatus.Expired
        ) revert BadStatus();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[34] private __gap;

    error ZeroAddress();
    error NotWhitelistRegistry();
    error NotEligible();
    error NotUser();
    error ZeroAmount();
    error ExceedsMax();
    error CapBuy();
    error CapBuyNonKyc();
    error CapSell();
    error BelowMinRedeem();
    error Timelocked();
    error Expired();
    error NotExpired();
    error NotInitiator();
    error BadStatus();
    error ZeroFiatValue();
    error BelowMinBuy();
    error BuyUsesAutoExecution();
    error InactiveAsset();
    error InactiveProvider();
    error AssetNotSupported();
    error ProviderBindingConflict();
    error UnsupportedRequestType();
    error ZeroSettlementRef();
}
