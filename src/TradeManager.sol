// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — TradeManager
/// @notice **Central orchestrator** for PRD trade requests: **Buy** completes in `createBuyRequestFor` (auto credit, no admin execute). Other flows: propose → approvals → `executeRequest` (admin) **or** `executeWithCoSignatures` (EIP-712 batch).
/// @dev UUPS upgradeable. Wiring:
/// - Reads policies from `GovernanceConfig` (caps, expiry, approval order).
/// - Checks `WhitelistRegistry.isEligible` / `isEligibleForNonKycUser` for user-facing operations.
/// - Uses `EscrowVault` for sell/redeem pending locks; `TimelockController` blocks sell/redeem when wallet or any user lot is locked.
/// - Mutates `GoldNFT` only via `TRADE_MANAGER_ROLE`.
/// - `setRoutingAddresses` must be called once after deploy: `assetProviderPayout`, `redeemSink`, `vaultBookkeeping` (legacy routing slot; burn debits AP pool).
/// **Gold amounts** in request structs and checks are **integer micrograms (µg)**. `1 gram = 1_000_000 µg`.
/// **Roles on this contract**: grant `USER_ROLE` to investors for gasless `create*For`; `AP_ROLE` / `VP_ROLE` / `AT_ROLE` / `PAP_ROLE` for `approveRequestFor` (non-Buy); `DEFAULT_ADMIN_ROLE` for `executeRequest` (non-Buy) and upgrades.
/// Gasless integrations call `*For` with explicit wallet/actor — Tresori relayer does not append ERC-2771 suffix bytes.
import {StoexRelayerGate} from "./base/StoexRelayerGate.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {StoexTypes} from "./libraries/StoexTypes.sol";
import {StoexRoles} from "./libraries/StoexRoles.sol";
import {IWhitelistRegistry} from "./interfaces/IWhitelistRegistry.sol";
import {IGovernanceConfig} from "./interfaces/IGovernanceConfig.sol";
import {IGoldNFT} from "./interfaces/IGoldNFT.sol";
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
    IGoldNFT public goldNFT;
    IEscrowVault public escrowVault;
    ITimelockController public timelockController;

    /// @dev PRD escrow routing: sell releases to asset provider; redeem to burn/sink address.
    address public assetProviderPayout;
    address public redeemSink;
    /// @dev On-chain account (whitelisted) whose `userHolding` backs aggregate vault / burn adjustments.
    address public vaultBookkeeping;

    bool public routingConfigured;
    address private _trustedForwarderValue;

    uint256 public nextRequestId;

    uint256 private _buyDay;
    uint256 private _buyDayAmountUg;
    uint256 private _sellDay;
    uint256 private _sellDayAmountUg;

    struct TradeRequest {
        StoexTypes.RequestType requestType;
        StoexTypes.RequestStatus status;
        address initiator;
        address targetUser;
        uint256 amountUg;
        bytes32 paymentRefId;
        bytes32 vaultReceiptId;
        string reason;
        uint256 createdAt;
        uint256 expiresAt;
        uint256 approvalsDone;
        StoexTypes.MintLotMeta mintLot;
        bool escrowLocked;
        uint256 fiatValue;
        bytes32 txDetailsHash;
    }

    mapping(uint256 => TradeRequest) private _requests;
    mapping(uint256 => mapping(uint256 => bool)) private _stepApproved;

    mapping(uint256 => uint256) public coSignNonce;

    /// @dev Cumulative executed buy `fiatValue` for non-KYC users (INR minor units); capped by `GovernanceConfig.nonKycMaxBuyFiatAmount`.
    mapping(address => uint256) private _nonKycFiatPurchased;

    bytes32 private constant CO_SIGN_TYPEHASH =
        keccak256("CoSignBatch(uint256 requestId,uint256 nonce,uint256 deadline)");

    event RequestCreated(
        uint256 indexed requestId,
        StoexTypes.RequestType requestType,
        address indexed initiator,
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
        address goldNFT_,
        address escrowVault_,
        address timelockController_,
        address trustedForwarder_
    ) external initializer {
        if (
            deployer_ == address(0) || governance_ == address(0) || whitelistRegistry_ == address(0) || goldNFT_ == address(0)
                || escrowVault_ == address(0) || timelockController_ == address(0) || trustedForwarder_ == address(0)
        ) revert ZeroAddress();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __EIP712_init("StoexGoldTrade", "1");
        __UUPSUpgradeable_init();
        __StoexDeployerAdmin_init_unchained(deployer_);

        governance = IGovernanceConfig(governance_);
        whitelistRegistry = IWhitelistRegistry(whitelistRegistry_);
        goldNFT = IGoldNFT(goldNFT_);
        escrowVault = IEscrowVault(escrowVault_);
        timelockController = ITimelockController(timelockController_);
        _trustedForwarderValue = trustedForwarder_;

        version = 1;
    }

    /// @notice Updates the trusted ERC-2771 forwarder used for meta-transactions.
    function setTrustedForwarder(address trustedForwarder_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (trustedForwarder_ == address(0)) revert ZeroAddress();
        _trustedForwarderValue = trustedForwarder_;
    }

    function trustedForwarder() public view override returns (address) {
        return _trustedForwarderValue;
    }

    /// @notice Called only by `WhitelistRegistry` during user onboarding to grant trade `USER_ROLE`.
    function grantUserRoleFromRegistry(address user) external {
        if (msg.sender != address(whitelistRegistry)) revert NotWhitelistRegistry();
        if (user == address(0)) revert ZeroAddress();
        _grantRole(StoexRoles.USER_ROLE, user);
    }

    /// @dev One-time routing configuration (escrow release destinations and vault burn bookkeeping).
    function setRoutingAddresses(address assetProviderPayout_, address redeemSink_, address vaultBookkeeping_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (routingConfigured) revert AlreadySet();
        if (assetProviderPayout_ == address(0) || redeemSink_ == address(0) || vaultBookkeeping_ == address(0)) {
            revert ZeroAddress();
        }
        assetProviderPayout = assetProviderPayout_;
        redeemSink = redeemSink_;
        vaultBookkeeping = vaultBookkeeping_;
        routingConfigured = true;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @param weightUg Gold amount in **micrograms** (must meet `minimumBuyGoldValueInUg` when set, and `maxAmountPerTx` cap).
    /// @param fiat_value INR minor units for this leg (e.g. paise); non-KYC cumulative cap uses this field.
    /// @param payment_ref Off-chain payment correlation id.
    /// @param txDetailsHash Audit hash for rails / settlement metadata.
    function createBuyRequestFor(
        address user,
        uint256 weightUg,
        uint256 fiat_value,
        bytes32 payment_ref,
        bytes32 txDetailsHash
    ) external onlyTrustedForwarder whenNotPaused nonReentrant returns (uint256 requestId) {
        _requireUserRole(user);
        return _createBuyRequest(user, weightUg, fiat_value, payment_ref, txDetailsHash);
    }

    function _createBuyRequest(
        address user,
        uint256 weightUg,
        uint256 fiat_value,
        bytes32 payment_ref,
        bytes32 txDetailsHash
    ) private returns (uint256 requestId) {
        if (!routingConfigured) revert RoutingNotSet();
        _checkBuyGoldAmount(weightUg);
        if (fiat_value == 0) revert ZeroFiatValue();
        if (goldNFT.totalAssetProviderBalance() < weightUg) revert InsufficientApInventory();

        if (whitelistRegistry.isEligible(user)) {
            _checkBuyCap(weightUg);
        } else if (whitelistRegistry.isEligibleForNonKycUser(user)) {
            _checkNonKycFiatCap(user, fiat_value);
        } else {
            revert NotEligible();
        }

        requestId = ++nextRequestId;
        _finalizeBuy(requestId, user, weightUg, fiat_value, payment_ref, txDetailsHash);
    }

    function createSellRequestFor(address user, uint256 amountUg, bytes32 payoutRefId)
        external
        onlyTrustedForwarder
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        _requireUserRole(user);
        return _createSellRequest(user, amountUg, payoutRefId);
    }

    function _createSellRequest(address user, uint256 amountUg, bytes32 payoutRefId)
        private
        returns (uint256 requestId)
    {
        if (!routingConfigured) revert RoutingNotSet();
        _requireEligible(user);
        _requireNotTimelocked(user);
        _checkAmountUg(amountUg);
        _checkSellCap(amountUg);

        requestId = ++nextRequestId;
        escrowVault.lockTokens(user, amountUg, StoexTypes.EscrowReason.Sell, requestId);
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        _requests[requestId] = TradeRequest({
            requestType: StoexTypes.RequestType.Sell,
            status: StoexTypes.RequestStatus.Proposed,
            initiator: user,
            targetUser: user,
            amountUg: amountUg,
            paymentRefId: payoutRefId,
            vaultReceiptId: bytes32(0),
            reason: "",
            createdAt: block.timestamp,
            expiresAt: exp,
            approvalsDone: 0,
            mintLot: _emptyLot(),
            escrowLocked: true,
            fiatValue: 0,
            txDetailsHash: bytes32(0)
        });

        emit RequestCreated(requestId, StoexTypes.RequestType.Sell, user, amountUg, 0);
    }

    function createRedeemRequestFor(address user, uint256 amountUg, bytes32 deliveryRefId)
        external
        onlyTrustedForwarder
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        _requireUserRole(user);
        return _createRedeemRequest(user, amountUg, deliveryRefId);
    }

    function _createRedeemRequest(address user, uint256 amountUg, bytes32 deliveryRefId)
        private
        returns (uint256 requestId)
    {
        if (!routingConfigured) revert RoutingNotSet();
        _requireEligible(user);
        _requireNotTimelocked(user);
        if (amountUg < governance.minRedeemAmountUg()) revert BelowMinRedeem();
        _checkAmountUg(amountUg);

        requestId = ++nextRequestId;
        escrowVault.lockTokens(user, amountUg, StoexTypes.EscrowReason.Redeem, requestId);
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        _requests[requestId] = TradeRequest({
            requestType: StoexTypes.RequestType.Redeem,
            status: StoexTypes.RequestStatus.Proposed,
            initiator: user,
            targetUser: user,
            amountUg: amountUg,
            paymentRefId: deliveryRefId,
            vaultReceiptId: bytes32(0),
            reason: "",
            createdAt: block.timestamp,
            expiresAt: exp,
            approvalsDone: 0,
            mintLot: _emptyLot(),
            escrowLocked: true,
            fiatValue: 0,
            txDetailsHash: bytes32(0)
        });

        emit RequestCreated(requestId, StoexTypes.RequestType.Redeem, user, amountUg, 0);
    }

    function proposeMintFor(address ap, uint256 amountUg, bytes32 vaultReceiptId, StoexTypes.MintLotMeta calldata lot)
        external
        onlyTrustedForwarder
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        if (!hasRole(StoexRoles.AP_ROLE, ap)) revert NotApprover();
        return _proposeMint(ap, amountUg, vaultReceiptId, lot);
    }

    function _proposeMint(address ap, uint256 amountUg, bytes32 vaultReceiptId, StoexTypes.MintLotMeta calldata lot)
        private
        returns (uint256 requestId)
    {
        if (!routingConfigured) revert RoutingNotSet();
        _checkAmountUg(amountUg);

        requestId = ++nextRequestId;
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        StoexTypes.MintLotMeta memory m = lot;
        m.amountUg = amountUg;
        m.vaultReceiptId = vaultReceiptId;

        _requests[requestId] = TradeRequest({
            requestType: StoexTypes.RequestType.Mint,
            status: StoexTypes.RequestStatus.Proposed,
            initiator: ap,
            targetUser: address(0),
            amountUg: amountUg,
            paymentRefId: bytes32(0),
            vaultReceiptId: vaultReceiptId,
            reason: "",
            createdAt: block.timestamp,
            expiresAt: exp,
            approvalsDone: 0,
            mintLot: m,
            escrowLocked: false,
            fiatValue: 0,
            txDetailsHash: bytes32(0)
        });

        emit RequestCreated(requestId, StoexTypes.RequestType.Mint, ap, amountUg, 0);
    }

    function proposeBurnFor(address ap, uint256 amountUg, bytes32 referenceId, string calldata reason_)
        external
        onlyTrustedForwarder
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        if (!hasRole(StoexRoles.AP_ROLE, ap)) revert NotApprover();
        return _proposeBurn(ap, amountUg, referenceId, reason_);
    }

    function _proposeBurn(address ap, uint256 amountUg, bytes32 referenceId, string calldata reason_)
        private
        returns (uint256 requestId)
    {
        if (!routingConfigured) revert RoutingNotSet();
        _checkAmountUg(amountUg);

        requestId = ++nextRequestId;
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        _requests[requestId] = TradeRequest({
            requestType: StoexTypes.RequestType.Burn,
            status: StoexTypes.RequestStatus.Proposed,
            initiator: ap,
            targetUser: address(0),
            amountUg: amountUg,
            paymentRefId: referenceId,
            vaultReceiptId: bytes32(0),
            reason: reason_,
            createdAt: block.timestamp,
            expiresAt: exp,
            approvalsDone: 0,
            mintLot: _emptyLot(),
            escrowLocked: false,
            fiatValue: 0,
            txDetailsHash: bytes32(0)
        });

        emit RequestCreated(requestId, StoexTypes.RequestType.Burn, ap, amountUg, 0);
    }

    function approveRequestFor(address approver, uint256 requestId) external onlyTrustedForwarder whenNotPaused nonReentrant {
        _approveRequest(approver, requestId);
    }

    function _approveRequest(address approver, uint256 requestId) private {
        TradeRequest storage r = _requests[requestId];
        _requirePending(r);
        if (block.timestamp > r.expiresAt) revert Expired();

        bytes32[] memory pol = governance.getApprovalPolicy(r.requestType);
        if (r.approvalsDone >= pol.length) revert FullyApproved();

        bytes32 requiredRole = pol[r.approvalsDone];
        if (!hasRole(requiredRole, approver)) revert NotApprover();
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
        TradeRequest storage r = _requests[requestId];
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
        TradeRequest storage r = _requests[requestId];
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
        TradeRequest storage r = _requests[requestId];
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
        TradeRequest storage r = _requests[requestId];
        if (r.requestType == StoexTypes.RequestType.Buy) revert BuyUsesAutoExecution();
        if (r.status != StoexTypes.RequestStatus.ATApproved) revert NotFullyApproved();
        _executeTrade(requestId, r);
        r.status = StoexTypes.RequestStatus.Executed;
        emit RequestExecuted(requestId, r.requestType);
    }

    /// @notice EIP-712 co-sign path: signatures must follow governance approval policy order for this request.
    function executeWithCoSignatures(uint256 requestId, uint256 nonce, uint256 deadline, bytes[] calldata signatures)
        external
        whenNotPaused
        nonReentrant
    {
        if (block.timestamp > deadline) revert SignatureDeadline();
        TradeRequest storage r = _requests[requestId];
        if (r.requestType == StoexTypes.RequestType.Buy) revert BuyUsesAutoExecution();
        if (block.timestamp > r.expiresAt) revert Expired();
        if (r.approvalsDone != 0) revert AlreadyProgressed();
        if (r.status != StoexTypes.RequestStatus.Proposed) revert BadStatus();

        bytes32[] memory pol = governance.getApprovalPolicy(r.requestType);
        if (signatures.length != pol.length) revert BadSignatures();

        if (nonce != coSignNonce[requestId]) revert BadNonce();

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CO_SIGN_TYPEHASH, requestId, nonce, deadline)));

        address last = address(0);
        for (uint256 i = 0; i < pol.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (signer == last) revert DuplicateSigner();
            if (!hasRole(pol[i], signer)) revert BadSigner();
            last = signer;
        }

        coSignNonce[requestId] = nonce + 1;
        emit CoSignConsumed(requestId, nonce);

        for (uint256 i = 0; i < pol.length; i++) {
            _stepApproved[requestId][i] = true;
        }
        r.approvalsDone = pol.length;
        r.status = StoexTypes.RequestStatus.ATApproved;

        _executeTrade(requestId, r);
        r.status = StoexTypes.RequestStatus.Executed;
        emit RequestExecuted(requestId, r.requestType);
    }

    function getRequest(uint256 requestId) external view returns (TradeRequest memory) {
        return _requests[requestId];
    }

    function getRequestStatus(uint256 requestId) external view returns (StoexTypes.RequestStatus) {
        return _requests[requestId].status;
    }

    /// @dev Assumes `createBuyRequest` already validated pool, caps, and eligibility (same tx, nonReentrant).
    function _finalizeBuy(
        uint256 requestId,
        address user,
        uint256 weightUg,
        uint256 fiat_value,
        bytes32 payment_ref,
        bytes32 txDetailsHash_
    ) private {
        if (goldNFT.tokenIdByBeneficiary(user) == 0) {
            goldNFT.mintCertificateForTrade(user);
        }
        goldNFT.transferFromAPToUser(user, weightUg, _emptyLot(), requestId, StoexTypes.TxType.Buy);

        if (whitelistRegistry.isEligible(user)) {
            _accrueBuy(weightUg);
        } else {
            _nonKycFiatPurchased[user] += fiat_value;
        }

        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        _requests[requestId] = TradeRequest({
            requestType: StoexTypes.RequestType.Buy,
            status: StoexTypes.RequestStatus.Executed,
            initiator: user,
            targetUser: user,
            amountUg: weightUg,
            paymentRefId: payment_ref,
            vaultReceiptId: bytes32(0),
            reason: "",
            createdAt: block.timestamp,
            expiresAt: exp,
            approvalsDone: 0,
            mintLot: _emptyLot(),
            escrowLocked: false,
            fiatValue: fiat_value,
            txDetailsHash: txDetailsHash_
        });

        emit RequestCreated(requestId, StoexTypes.RequestType.Buy, user, weightUg, fiat_value);
        emit RequestExecuted(requestId, StoexTypes.RequestType.Buy);
    }

    function _executeTrade(uint256 requestId, TradeRequest storage r) private {
        if (r.requestType == StoexTypes.RequestType.Sell) {
            _requireEligible(r.targetUser);
            _checkSellCap(r.amountUg);
            _accrueSell(r.amountUg);
            escrowVault.releaseEscrow(requestId, assetProviderPayout);
            r.escrowLocked = false;
            goldNFT.decreaseSupply(r.targetUser, r.amountUg, StoexTypes.TxType.Sell, requestId);
        } else if (r.requestType == StoexTypes.RequestType.Redeem) {
            _requireEligible(r.targetUser);
            escrowVault.releaseEscrow(requestId, redeemSink);
            r.escrowLocked = false;
            goldNFT.decreaseSupply(r.targetUser, r.amountUg, StoexTypes.TxType.Redeem, requestId);
        } else if (r.requestType == StoexTypes.RequestType.Mint) {
            uint256 lotId = goldNFT.mintToPool(r.amountUg, r.mintLot, requestId);
            uint256 dur = governance.defaultTimelockDuration();
            if (dur > 0) {
                timelockController.applyMintLotTimelock(lotId, block.timestamp + dur);
            }
        } else if (r.requestType == StoexTypes.RequestType.Burn) {
            goldNFT.burnFromPool(r.amountUg, requestId);
        }
    }

    /// @dev PRD burn reduces unsold AP pool inventory and total system supply.
    function _emptyLot() private pure returns (StoexTypes.MintLotMeta memory m) {
        return m;
    }

    function _requireEligible(address u) private view {
        if (!whitelistRegistry.isEligible(u)) revert NotEligible();
    }

    function _requireUserRole(address user) private view {
        if (!hasRole(StoexRoles.USER_ROLE, user)) revert NotUser();
    }

    function _requireNotTimelocked(address user) private view {
        if (timelockController.isTimelocked(user)) revert Timelocked();
        uint256[] memory lots = goldNFT.getUserLotIds(user);
        for (uint256 i = 0; i < lots.length; i++) {
            uint256 exp = timelockController.getLotTimelockExpiry(lots[i]);
            if (exp != 0 && block.timestamp < exp) revert Timelocked();
        }
    }

    function _checkAmountUg(uint256 amountUg) private view {
        if (amountUg == 0) revert ZeroAmount();
        if (amountUg > governance.maxAmountPerTx()) revert ExceedsMax();
    }

    /// @dev Buy-specific: microgram bounds including admin `minimumBuyGoldValueInUg` (skipped when that value is 0).
    function _checkBuyGoldAmount(uint256 weightUg) private view {
        if (weightUg == 0) revert ZeroAmount();
        if (weightUg > governance.maxAmountPerTx()) revert ExceedsMax();
        uint256 minUg = governance.minimumBuyGoldValueInUg();
        if (minUg > 0 && weightUg < minUg) revert BelowMinBuyGold();
    }

    function _checkBuyCap(uint256 amountUg) private view {
        uint256 day = block.timestamp / 1 days;
        uint256 used = _buyDay == day ? _buyDayAmountUg : 0;
        if (used + amountUg > governance.dailyBuyCap()) revert CapBuy();
    }

    function _checkNonKycFiatCap(address user, uint256 fiatValue_) private view {
        if (_nonKycFiatPurchased[user] + fiatValue_ > governance.nonKycMaxBuyFiatAmount()) revert CapBuyNonKyc();
    }

    function _checkSellCap(uint256 amountUg) private view {
        uint256 day = block.timestamp / 1 days;
        uint256 used = _sellDay == day ? _sellDayAmountUg : 0;
        if (used + amountUg > governance.dailySellCap()) revert CapSell();
    }

    function _accrueBuy(uint256 amountUg) private {
        uint256 day = block.timestamp / 1 days;
        if (_buyDay != day) {
            _buyDay = day;
            _buyDayAmountUg = 0;
        }
        _buyDayAmountUg += amountUg;
    }

    function _accrueSell(uint256 amountUg) private {
        uint256 day = block.timestamp / 1 days;
        if (_sellDay != day) {
            _sellDay = day;
            _sellDayAmountUg = 0;
        }
        _sellDayAmountUg += amountUg;
    }

    function _requirePending(TradeRequest storage r) private view {
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

    uint256[37] private __gap;

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
    error RoutingNotSet();
    error AlreadySet();
    error ZeroFiatValue();
    error InsufficientApInventory();
    error BelowMinBuyGold();
    error BuyUsesAutoExecution();
}
