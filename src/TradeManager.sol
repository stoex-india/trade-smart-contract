// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TradeManager
/// @notice Central orchestrator for multi-asset, multi-provider trade requests.
import {StoexRelayerGate} from "./base/StoexRelayerGate.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

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
    EIP712Upgradeable,
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
    mapping(uint256 => mapping(uint256 => bool)) private _stepApproved;
    mapping(uint256 => uint256) public coSignNonce;
    mapping(address => uint256) private _nonKycFiatPurchased;

    bytes32 private constant CO_SIGN_TYPEHASH =
        keccak256("CoSignBatch(uint256 requestId,uint256 nonce,uint256 deadline)");

    event RequestCreated(
        uint256 indexed requestId,
        bytes32 indexed assetId,
        bytes32 indexed providerId,
        StoexTypes.RequestType requestType,
        address initiator,
        uint256 amountUg,
        uint256 fiatValue
    );
    event RequestApproved(uint256 indexed requestId, bytes32 indexed role, address approver);
    event RequestRejected(uint256 indexed requestId, bytes32 indexed role, address rejector, string reason);
    event RequestExecuted(uint256 indexed requestId, StoexTypes.RequestType requestType);
    event RequestCancelled(uint256 indexed requestId);
    event RequestExpired(uint256 indexed requestId);
    event CoSignConsumed(uint256 indexed requestId, uint256 nonce);

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
                || assetRegistry_ == address(0) || assetProviderRegistry_ == address(0) || trustedForwarder_ == address(0)
        ) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __EIP712_init("StoexTrade", "2");
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

        version = 2;
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
        if (assetLedger.providerPoolBalance(assetId, providerId) < weightUg) revert InsufficientApInventory();

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

    function createSellRequestFor(
        address user,
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        bytes32 payoutRefId
    ) external onlyTrustedForwarder whenNotPaused nonReentrant returns (uint256 requestId) {
        _requireUserRole(user);
        return _createSellRequest(user, assetId, providerId, amountUg, payoutRefId);
    }

    function _createSellRequest(
        address user,
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        bytes32 payoutRefId
    ) private returns (uint256 requestId) {
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
            payoutRefId,
            bytes32(0),
            "",
            exp,
            TradeManagerLib.emptyLot(),
            true
        );

        emit RequestCreated(requestId, assetId, providerId, StoexTypes.RequestType.Sell, user, amountUg, 0);
    }

    function createRedeemRequestFor(
        address user,
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        bytes32 deliveryRefId
    ) external onlyTrustedForwarder whenNotPaused nonReentrant returns (uint256 requestId) {
        _requireUserRole(user);
        return _createRedeemRequest(user, assetId, providerId, amountUg, deliveryRefId);
    }

    function _createRedeemRequest(
        address user,
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        bytes32 deliveryRefId
    ) private returns (uint256 requestId) {
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
            deliveryRefId,
            bytes32(0),
            "",
            exp,
            TradeManagerLib.emptyLot(),
            true
        );

        emit RequestCreated(requestId, assetId, providerId, StoexTypes.RequestType.Redeem, user, amountUg, 0);
    }

    function proposeMintFor(
        address ap,
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        bytes32 vaultReceiptId,
        StoexTypes.MintLotMeta calldata lot
    ) external onlyTrustedForwarder whenNotPaused nonReentrant returns (uint256 requestId) {
        if (!hasRole(StoexRoles.AP_ROLE, ap)) revert NotApprover();
        if (!assetProviderRegistry.isOperator(providerId, ap)) revert NotProviderOperator();
        return _proposeMint(ap, assetId, providerId, amountUg, vaultReceiptId, lot);
    }

    function _proposeMint(
        address ap,
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        bytes32 vaultReceiptId,
        StoexTypes.MintLotMeta calldata lot
    ) private returns (uint256 requestId) {
        _validateAssetProvider(assetId, providerId);
        _checkAmountUg(amountUg);

        requestId = ++nextRequestId;
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        StoexTypes.MintLotMeta memory m = lot;
        m.assetId = assetId;
        m.providerId = providerId;
        m.amountUg = amountUg;
        m.vaultReceiptId = vaultReceiptId;

        TradeManagerLib.initPendingRequest(
            _requests[requestId],
            assetId,
            providerId,
            StoexTypes.RequestType.Mint,
            ap,
            address(0),
            amountUg,
            bytes32(0),
            vaultReceiptId,
            "",
            exp,
            m,
            false
        );

        emit RequestCreated(requestId, assetId, providerId, StoexTypes.RequestType.Mint, ap, amountUg, 0);
    }

    function proposeBurnFor(
        address ap,
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        bytes32 referenceId,
        string calldata reason_
    ) external onlyTrustedForwarder whenNotPaused nonReentrant returns (uint256 requestId) {
        if (!hasRole(StoexRoles.AP_ROLE, ap)) revert NotApprover();
        if (!assetProviderRegistry.isOperator(providerId, ap)) revert NotProviderOperator();
        return _proposeBurn(ap, assetId, providerId, amountUg, referenceId, reason_);
    }

    function _proposeBurn(
        address ap,
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        bytes32 referenceId,
        string calldata reason_
    ) private returns (uint256 requestId) {
        _validateAssetProvider(assetId, providerId);
        _checkAmountUg(amountUg);

        requestId = ++nextRequestId;
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        TradeManagerLib.initPendingRequest(
            _requests[requestId],
            assetId,
            providerId,
            StoexTypes.RequestType.Burn,
            ap,
            address(0),
            amountUg,
            referenceId,
            bytes32(0),
            reason_,
            exp,
            TradeManagerLib.emptyLot(),
            false
        );

        emit RequestCreated(requestId, assetId, providerId, StoexTypes.RequestType.Burn, ap, amountUg, 0);
    }

    function approveRequestFor(address approver, uint256 requestId) external onlyTrustedForwarder whenNotPaused nonReentrant {
        _approveRequest(approver, requestId);
    }

    function _approveRequest(address approver, uint256 requestId) private {
        StoexTypes.TradeRequest storage r = _requests[requestId];
        _requirePending(r);
        if (block.timestamp > r.expiresAt) revert Expired();

        bytes32[] memory pol = governance.getApprovalPolicy(r.requestType);
        if (r.approvalsDone >= pol.length) revert FullyApproved();

        bytes32 requiredRole = pol[r.approvalsDone];
        if (!hasRole(requiredRole, approver)) revert NotApprover();
        if (requiredRole == StoexRoles.AP_ROLE && !assetProviderRegistry.isOperator(r.providerId, approver)) {
            revert NotProviderOperator();
        }

        uint256 step = r.approvalsDone;
        if (_stepApproved[requestId][step]) revert StepDone();

        _stepApproved[requestId][step] = true;
        bytes32 approvedRole = requiredRole;
        r.approvalsDone += 1;

        if (r.approvalsDone == pol.length) {
            r.status = StoexTypes.RequestStatus.ATApproved;
        } else {
            r.status = _roleMilestone(approvedRole);
        }

        emit RequestApproved(requestId, approvedRole, approver);
    }

    function rejectRequestFor(address rejector, uint256 requestId, string calldata reason_)
        external
        onlyTrustedForwarder
        whenNotPaused
        nonReentrant
    {
        _rejectRequest(rejector, requestId, reason_);
    }

    function _rejectRequest(address rejector, uint256 requestId, string calldata reason_) private {
        StoexTypes.TradeRequest storage r = _requests[requestId];
        _requirePending(r);
        if (
            !hasRole(StoexRoles.AP_ROLE, rejector) && !hasRole(StoexRoles.VP_ROLE, rejector)
                && !hasRole(StoexRoles.AT_ROLE, rejector) && !hasRole(StoexRoles.PAP_ROLE, rejector)
        ) {
            revert NotApprover();
        }

        if (r.escrowLocked) {
            escrowVault.unlockTokens(requestId);
        }
        r.escrowLocked = false;
        r.status = StoexTypes.RequestStatus.Rejected;
        emit RequestRejected(requestId, bytes32(0), rejector, reason_);
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

    function executeRequest(uint256 requestId) external onlyRole(DEFAULT_ADMIN_ROLE) whenNotPaused nonReentrant {
        StoexTypes.TradeRequest storage r = _requests[requestId];
        if (r.requestType == StoexTypes.RequestType.Buy) revert BuyUsesAutoExecution();
        if (r.status != StoexTypes.RequestStatus.ATApproved) revert NotFullyApproved();
        TradeManagerLib.executeTrade(
            r,
            requestId,
            _dayCaps,
            whitelistRegistry,
            governance,
            assetLedger,
            assetProviderRegistry,
            escrowVault,
            timelockController
        );
        r.status = StoexTypes.RequestStatus.Executed;
        emit RequestExecuted(requestId, r.requestType);
    }

    function executeWithCoSignatures(uint256 requestId, uint256 nonce, uint256 deadline, bytes[] calldata signatures)
        external
        whenNotPaused
        nonReentrant
    {
        if (block.timestamp > deadline) revert SignatureDeadline();
        StoexTypes.TradeRequest storage r = _requests[requestId];
        if (r.requestType == StoexTypes.RequestType.Buy) revert BuyUsesAutoExecution();
        if (block.timestamp > r.expiresAt) revert Expired();
        if (r.approvalsDone != 0) revert AlreadyProgressed();
        if (r.status != StoexTypes.RequestStatus.Proposed) revert BadStatus();

        bytes32[] memory pol = governance.getApprovalPolicy(r.requestType);
        if (signatures.length != pol.length) revert BadSignatures();

        if (nonce != coSignNonce[requestId]) revert BadNonce();

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CO_SIGN_TYPEHASH, requestId, nonce, deadline)));

        TradeManagerLib.verifyCoSigners(digest, signatures, pol, r.providerId, this, assetProviderRegistry);

        coSignNonce[requestId] = nonce + 1;
        emit CoSignConsumed(requestId, nonce);

        for (uint256 i = 0; i < pol.length; i++) {
            _stepApproved[requestId][i] = true;
        }
        r.approvalsDone = pol.length;
        r.status = StoexTypes.RequestStatus.ATApproved;

        TradeManagerLib.executeTrade(
            r,
            requestId,
            _dayCaps,
            whitelistRegistry,
            governance,
            assetLedger,
            assetProviderRegistry,
            escrowVault,
            timelockController
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

    function _roleMilestone(bytes32 role) private pure returns (StoexTypes.RequestStatus) {
        if (role == StoexRoles.AP_ROLE) return StoexTypes.RequestStatus.APApproved;
        if (role == StoexRoles.VP_ROLE) return StoexTypes.RequestStatus.VPApproved;
        if (role == StoexRoles.PAP_ROLE) return StoexTypes.RequestStatus.PAPApproved;
        if (role == StoexRoles.AT_ROLE) return StoexTypes.RequestStatus.ATApproved;
        revert InvalidRole();
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
    error NotApprover();
    error NotProviderOperator();
    error StepDone();
    error FullyApproved();
    error Expired();
    error NotExpired();
    error NotInitiator();
    error BadStatus();
    error NotFullyApproved();
    error AlreadyProgressed();
    error BadSignatures();
    error BadNonce();
    error BadSigner();
    error DuplicateSigner();
    error InvalidRole();
    error SignatureDeadline();
    error ZeroFiatValue();
    error InsufficientApInventory();
    error BelowMinBuy();
    error BuyUsesAutoExecution();
    error InactiveAsset();
    error InactiveProvider();
    error AssetNotSupported();
    error ProviderBindingConflict();
}
