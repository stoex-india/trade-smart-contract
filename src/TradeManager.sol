// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — TradeManager
/// @notice **Central orchestrator** for PRD trade requests: Buy, Sell, Redeem, Mint, Burn — propose → ordered approvals → `executeRequest` (admin) **or** `executeWithCoSignatures` (EIP-712 batch).
/// @dev UUPS upgradeable. Wiring:
/// - Reads policies from `GovernanceConfig` (caps, expiry, approval order).
/// - Checks `WhitelistRegistry.isEligible` for user-facing operations.
/// - Uses `EscrowVault` for sell/redeem pending locks; `TimelockController` blocks sell/redeem when wallet or any user lot is locked.
/// - Mutates `GoldNFT` only via `TRADE_MANAGER_ROLE`.
/// - `setRoutingAddresses` must be called once after deploy: `assetProviderPayout`, `redeemSink`, `vaultBookkeeping` (burn debits this whitelisted account).
/// **Roles on this contract**: grant `USER_ROLE` to investors for `create*`; `AP_ROLE` / `VP_ROLE` / `AT_ROLE` / `PAP_ROLE` for `approveRequest`; `DEFAULT_ADMIN_ROLE` for `executeRequest` and upgrades.
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {StoexDeployerAdminUpgradeable} from "./base/StoexDeployerAdminUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ERC2771ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
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
    ERC2771ContextUpgradeable,
    UUPSUpgradeable
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
    uint256 private _buyDayGrams;
    uint256 private _sellDay;
    uint256 private _sellDayGrams;

    struct TradeRequest {
        StoexTypes.RequestType requestType;
        StoexTypes.RequestStatus status;
        address initiator;
        address targetUser;
        uint256 grams;
        bytes32 paymentRefId;
        bytes32 vaultReceiptId;
        string reason;
        uint256 createdAt;
        uint256 expiresAt;
        uint256 approvalsDone;
        StoexTypes.MintLotMeta mintLot;
        bool escrowLocked;
    }

    mapping(uint256 => TradeRequest) private _requests;
    mapping(uint256 => mapping(uint256 => bool)) private _stepApproved;

    mapping(uint256 => uint256) public coSignNonce;

    bytes32 private constant CO_SIGN_TYPEHASH =
        keccak256("CoSignBatch(uint256 requestId,uint256 nonce,uint256 deadline)");

    event RequestCreated(
        uint256 indexed requestId, StoexTypes.RequestType requestType, address indexed initiator, uint256 grams
    );
    event RequestApproved(uint256 indexed requestId, bytes32 indexed role, address approver);
    event RequestRejected(uint256 indexed requestId, bytes32 indexed role, address rejector, string reason);
    event RequestExecuted(uint256 indexed requestId, StoexTypes.RequestType requestType);
    event RequestCancelled(uint256 indexed requestId);
    event RequestExpired(uint256 indexed requestId);
    event CoSignConsumed(uint256 indexed requestId, uint256 nonce);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() ERC2771ContextUpgradeable(address(0)) {
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

    function createBuyRequest(uint256 grams, bytes32 paymentRefId) external onlyRole(StoexRoles.USER_ROLE) whenNotPaused nonReentrant returns (uint256 requestId) {
        if (!routingConfigured) revert RoutingNotSet();
        address user = _msgSender();
        _checkGrams(grams);
        if (whitelistRegistry.isEligible(user)) {
            _checkBuyCap(grams);
        } else if (whitelistRegistry.isEligibleForRestrictedBuy(user)) {
            _checkNonKycHoldingCap(user, grams);
        } else {
            revert NotEligible();
        }

        requestId = ++nextRequestId;
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        _requests[requestId] = TradeRequest({
            requestType: StoexTypes.RequestType.Buy,
            status: StoexTypes.RequestStatus.Proposed,
            initiator: user,
            targetUser: user,
            grams: grams,
            paymentRefId: paymentRefId,
            vaultReceiptId: bytes32(0),
            reason: "",
            createdAt: block.timestamp,
            expiresAt: exp,
            approvalsDone: 0,
            mintLot: _emptyLot(),
            escrowLocked: false
        });

        emit RequestCreated(requestId, StoexTypes.RequestType.Buy, user, grams);
    }

    function createSellRequest(uint256 grams, bytes32 payoutRefId) external onlyRole(StoexRoles.USER_ROLE) whenNotPaused nonReentrant returns (uint256 requestId) {
        if (!routingConfigured) revert RoutingNotSet();
        address user = _msgSender();
        _requireEligible(user);
        _requireNotTimelocked(user);
        _checkGrams(grams);
        _checkSellCap(grams);

        requestId = ++nextRequestId;
        escrowVault.lockTokens(user, grams, StoexTypes.EscrowReason.Sell, requestId);
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        _requests[requestId] = TradeRequest({
            requestType: StoexTypes.RequestType.Sell,
            status: StoexTypes.RequestStatus.Proposed,
            initiator: user,
            targetUser: user,
            grams: grams,
            paymentRefId: payoutRefId,
            vaultReceiptId: bytes32(0),
            reason: "",
            createdAt: block.timestamp,
            expiresAt: exp,
            approvalsDone: 0,
            mintLot: _emptyLot(),
            escrowLocked: true
        });

        emit RequestCreated(requestId, StoexTypes.RequestType.Sell, user, grams);
    }

    function createRedeemRequest(uint256 grams, bytes32 deliveryRefId) external onlyRole(StoexRoles.USER_ROLE) whenNotPaused nonReentrant returns (uint256 requestId) {
        if (!routingConfigured) revert RoutingNotSet();
        address user = _msgSender();
        _requireEligible(user);
        _requireNotTimelocked(user);
        if (grams < governance.minRedeemQuantity()) revert BelowMinRedeem();
        _checkGrams(grams);

        requestId = ++nextRequestId;
        escrowVault.lockTokens(user, grams, StoexTypes.EscrowReason.Redeem, requestId);
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        _requests[requestId] = TradeRequest({
            requestType: StoexTypes.RequestType.Redeem,
            status: StoexTypes.RequestStatus.Proposed,
            initiator: user,
            targetUser: user,
            grams: grams,
            paymentRefId: deliveryRefId,
            vaultReceiptId: bytes32(0),
            reason: "",
            createdAt: block.timestamp,
            expiresAt: exp,
            approvalsDone: 0,
            mintLot: _emptyLot(),
            escrowLocked: true
        });

        emit RequestCreated(requestId, StoexTypes.RequestType.Redeem, user, grams);
    }

    function proposeMint(uint256 grams, address creditTo, bytes32 vaultReceiptId, StoexTypes.MintLotMeta calldata lot)
        external
        onlyRole(StoexRoles.AP_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        if (!routingConfigured) revert RoutingNotSet();
        _requireEligible(creditTo);
        _checkGrams(grams);

        requestId = ++nextRequestId;
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        StoexTypes.MintLotMeta memory m = lot;
        m.grams = grams;
        m.vaultReceiptId = vaultReceiptId;

        _requests[requestId] = TradeRequest({
            requestType: StoexTypes.RequestType.Mint,
            status: StoexTypes.RequestStatus.Proposed,
            initiator: _msgSender(),
            targetUser: creditTo,
            grams: grams,
            paymentRefId: bytes32(0),
            vaultReceiptId: vaultReceiptId,
            reason: "",
            createdAt: block.timestamp,
            expiresAt: exp,
            approvalsDone: 0,
            mintLot: m,
            escrowLocked: false
        });

        emit RequestCreated(requestId, StoexTypes.RequestType.Mint, _msgSender(), grams);
    }

    function proposeBurn(uint256 grams, bytes32 referenceId, string calldata reason_)
        external
        onlyRole(StoexRoles.AP_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 requestId)
    {
        if (!routingConfigured) revert RoutingNotSet();
        _checkGrams(grams);

        requestId = ++nextRequestId;
        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        _requests[requestId] = TradeRequest({
            requestType: StoexTypes.RequestType.Burn,
            status: StoexTypes.RequestStatus.Proposed,
            initiator: _msgSender(),
            targetUser: address(0),
            grams: grams,
            paymentRefId: referenceId,
            vaultReceiptId: bytes32(0),
            reason: reason_,
            createdAt: block.timestamp,
            expiresAt: exp,
            approvalsDone: 0,
            mintLot: _emptyLot(),
            escrowLocked: false
        });

        emit RequestCreated(requestId, StoexTypes.RequestType.Burn, _msgSender(), grams);
    }

    function approveRequest(uint256 requestId) external whenNotPaused nonReentrant {
        TradeRequest storage r = _requests[requestId];
        _requirePending(r);
        if (block.timestamp > r.expiresAt) revert Expired();

        bytes32[] memory pol = governance.getApprovalPolicy(r.requestType);
        if (r.approvalsDone >= pol.length) revert FullyApproved();

        bytes32 requiredRole = pol[r.approvalsDone];
        if (!hasRole(requiredRole, _msgSender())) revert NotApprover();
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

        emit RequestApproved(requestId, approvedRole, _msgSender());
    }

    function rejectRequest(uint256 requestId, string calldata reason_) external whenNotPaused nonReentrant {
        TradeRequest storage r = _requests[requestId];
        _requirePending(r);
        if (
            !hasRole(StoexRoles.AP_ROLE, _msgSender()) && !hasRole(StoexRoles.VP_ROLE, _msgSender())
                && !hasRole(StoexRoles.AT_ROLE, _msgSender()) && !hasRole(StoexRoles.PAP_ROLE, _msgSender())
        ) {
            revert NotApprover();
        }

        if (r.escrowLocked) {
            escrowVault.unlockTokens(requestId);
        }
        r.escrowLocked = false;
        r.status = StoexTypes.RequestStatus.Rejected;
        emit RequestRejected(requestId, bytes32(0), _msgSender(), reason_);
    }

    function cancelRequest(uint256 requestId) external whenNotPaused nonReentrant {
        TradeRequest storage r = _requests[requestId];
        if (r.initiator != _msgSender()) revert NotInitiator();
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

    /// @notice EIP-712 digest for `CoSignBatch(uint256 requestId,uint256 nonce,uint256 deadline)` (for wallets & tests).
    function hashCoSignBatch(uint256 requestId, uint256 nonce, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CO_SIGN_TYPEHASH, requestId, nonce, deadline)));
    }

    function getUserRequests(address user, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, TradeRequest[] memory rows)
    {
        if (limit > 100) limit = 100;
        uint256 n = nextRequestId;
        uint256[] memory tmp = new uint256[](n);
        uint256 c;
        for (uint256 i = 1; i <= n; i++) {
            if (_requests[i].initiator == user || _requests[i].targetUser == user) {
                tmp[c++] = i;
            }
        }
        if (offset >= c) {
            return (new uint256[](0), new TradeRequest[](0));
        }
        uint256 end = offset + limit;
        if (end > c) end = c;
        uint256 len = end - offset;
        ids = new uint256[](len);
        rows = new TradeRequest[](len);
        for (uint256 j = 0; j < len; j++) {
            uint256 id = tmp[offset + j];
            ids[j] = id;
            rows[j] = _requests[id];
        }
    }

    function _executeTrade(uint256 requestId, TradeRequest storage r) private {
        if (r.requestType == StoexTypes.RequestType.Buy) {
            if (whitelistRegistry.isEligible(r.targetUser)) {
                _checkBuyCap(r.grams);
                _accrueBuy(r.grams);
            } else if (whitelistRegistry.isEligibleForRestrictedBuy(r.targetUser)) {
                _checkNonKycHoldingCap(r.targetUser, r.grams);
            } else {
                revert NotEligible();
            }
            if (goldNFT.tokenIdByBeneficiary(r.targetUser) == 0) {
                goldNFT.mintCertificateForTrade(r.targetUser);
            }
            goldNFT.increaseSupply(r.targetUser, r.grams, _emptyLot(), requestId, StoexTypes.TxType.Buy);
        } else if (r.requestType == StoexTypes.RequestType.Sell) {
            _requireEligible(r.targetUser);
            _checkSellCap(r.grams);
            _accrueSell(r.grams);
            escrowVault.releaseEscrow(requestId, assetProviderPayout);
            r.escrowLocked = false;
            goldNFT.decreaseSupply(r.targetUser, r.grams, StoexTypes.TxType.Sell, requestId);
        } else if (r.requestType == StoexTypes.RequestType.Redeem) {
            _requireEligible(r.targetUser);
            escrowVault.releaseEscrow(requestId, redeemSink);
            r.escrowLocked = false;
            goldNFT.decreaseSupply(r.targetUser, r.grams, StoexTypes.TxType.Redeem, requestId);
        } else if (r.requestType == StoexTypes.RequestType.Mint) {
            address u = r.targetUser;
            _requireEligible(u);
            if (goldNFT.tokenIdByBeneficiary(u) == 0) {
                goldNFT.mintCertificateForTrade(u);
            }
            uint256 lotId = goldNFT.increaseSupply(u, r.grams, r.mintLot, requestId, StoexTypes.TxType.Mint);
            uint256 dur = governance.defaultTimelockDuration();
            if (dur > 0) {
                timelockController.applyMintLotTimelock(lotId, block.timestamp + dur);
            }
        } else if (r.requestType == StoexTypes.RequestType.Burn) {
            _requireEligible(vaultBookkeeping);
            goldNFT.decreaseSupply(vaultBookkeeping, r.grams, StoexTypes.TxType.Burn, requestId);
        }
    }

    /// @dev PRD burn reduces system supply from the configured bookkeeping holder.
    function _emptyLot() private pure returns (StoexTypes.MintLotMeta memory m) {
        return m;
    }

    function _requireEligible(address u) private view {
        if (!whitelistRegistry.isEligible(u)) revert NotEligible();
    }

    function _requireNotTimelocked(address user) private view {
        if (timelockController.isTimelocked(user)) revert Timelocked();
        uint256[] memory lots = goldNFT.getUserLotIds(user);
        for (uint256 i = 0; i < lots.length; i++) {
            uint256 exp = timelockController.getLotTimelockExpiry(lots[i]);
            if (exp != 0 && block.timestamp < exp) revert Timelocked();
        }
    }

    function _checkGrams(uint256 grams) private view {
        if (grams == 0) revert ZeroAmount();
        if (grams > governance.maxGramsPerTx()) revert ExceedsMax();
    }

    function _checkBuyCap(uint256 grams) private view {
        uint256 day = block.timestamp / 1 days;
        uint256 used = _buyDay == day ? _buyDayGrams : 0;
        if (used + grams > governance.dailyBuyCap()) revert CapBuy();
    }

    function _checkNonKycHoldingCap(address user, uint256 grams) private view {
        if (goldNFT.userHolding(user) + grams > governance.nonKycMaxHoldingCap()) revert CapBuyNonKyc();
    }

    function _checkSellCap(uint256 grams) private view {
        uint256 day = block.timestamp / 1 days;
        uint256 used = _sellDay == day ? _sellDayGrams : 0;
        if (used + grams > governance.dailySellCap()) revert CapSell();
    }

    function _accrueBuy(uint256 grams) private {
        uint256 day = block.timestamp / 1 days;
        if (_buyDay != day) {
            _buyDay = day;
            _buyDayGrams = 0;
        }
        _buyDayGrams += grams;
    }

    function _accrueSell(uint256 grams) private {
        uint256 day = block.timestamp / 1 days;
        if (_sellDay != day) {
            _sellDay = day;
            _sellDayGrams = 0;
        }
        _sellDayGrams += grams;
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

    uint256[35] private __gap;

    error ZeroAddress();
    error NotEligible();
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
}
