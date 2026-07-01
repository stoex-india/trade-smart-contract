// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexTypes} from "./StoexTypes.sol";
import {StoexRoles} from "./StoexRoles.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IWhitelistRegistry} from "../interfaces/IWhitelistRegistry.sol";
import {IGovernanceConfig} from "../interfaces/IGovernanceConfig.sol";
import {IAssetLedger} from "../interfaces/IAssetLedger.sol";
import {IAssetProviderRegistry} from "../interfaces/IAssetProviderRegistry.sol";
import {IEscrowVault} from "../interfaces/IEscrowVault.sol";
import {ITimelockController} from "../interfaces/ITimelockController.sol";

/// @dev External library to keep `TradeManager` under the EIP-170 size limit.
library TradeManagerLib {
    struct DayCaps {
        mapping(bytes32 => uint256) buyDay;
        mapping(bytes32 => uint256) buyDayAmountUg;
        mapping(bytes32 => uint256) sellDay;
        mapping(bytes32 => uint256) sellDayAmountUg;
    }

    function initPendingRequest(
        StoexTypes.TradeRequest storage r,
        bytes32 assetId,
        bytes32 providerId,
        StoexTypes.RequestType requestType,
        address initiator,
        address targetUser,
        uint256 amountUg,
        bytes32 refId,
        bytes32 vaultReceiptId,
        string calldata reason_,
        uint256 expiry,
        StoexTypes.MintLotMeta memory mintLot,
        bool escrowLocked
    ) external {
        r.assetId = assetId;
        r.providerId = providerId;
        r.requestType = requestType;
        r.status = StoexTypes.RequestStatus.Proposed;
        r.initiator = initiator;
        r.targetUser = targetUser;
        r.amountUg = amountUg;
        r.paymentRefId = refId;
        r.vaultReceiptId = vaultReceiptId;
        r.reason = reason_;
        r.createdAt = block.timestamp;
        r.expiresAt = expiry;
        r.approvalsDone = 0;
        r.mintLot = mintLot;
        r.escrowLocked = escrowLocked;
        r.fiatValue = 0;
        r.txDetailsHash = bytes32(0);
    }

    function executeTrade(
        StoexTypes.TradeRequest storage r,
        uint256 requestId,
        DayCaps storage caps,
        IWhitelistRegistry whitelistRegistry,
        IGovernanceConfig governance,
        IAssetLedger assetLedger,
        IAssetProviderRegistry assetProviderRegistry,
        IEscrowVault escrowVault,
        ITimelockController timelockController
    ) external {
        if (r.requestType == StoexTypes.RequestType.Sell) {
            if (!whitelistRegistry.isEligible(r.targetUser)) revert NotEligible();
            _checkSellCap(caps, governance, r.assetId, r.amountUg);
            _accrueSell(caps, r.assetId, r.amountUg);
            address payout = assetProviderRegistry.getSellPayout(r.providerId, r.assetId);
            escrowVault.releaseEscrow(requestId, payout);
            r.escrowLocked = false;
            assetLedger.decreaseSupply(r.assetId, r.providerId, r.targetUser, r.amountUg, StoexTypes.TxType.Sell, requestId);
        } else if (r.requestType == StoexTypes.RequestType.Redeem) {
            if (!whitelistRegistry.isEligible(r.targetUser)) revert NotEligible();
            address sink = assetProviderRegistry.getRedeemSink(r.providerId, r.assetId);
            escrowVault.releaseEscrow(requestId, sink);
            r.escrowLocked = false;
            assetLedger.decreaseSupply(r.assetId, r.providerId, r.targetUser, r.amountUg, StoexTypes.TxType.Redeem, requestId);
        } else if (r.requestType == StoexTypes.RequestType.Mint) {
            uint256 lotId = assetLedger.mintToPool(r.assetId, r.providerId, r.amountUg, r.mintLot, requestId);
            uint256 dur = governance.defaultTimelockDuration();
            if (dur > 0) {
                timelockController.applyMintLotTimelock(lotId, block.timestamp + dur);
            }
            lotId;
        } else if (r.requestType == StoexTypes.RequestType.Burn) {
            assetLedger.burnFromPool(r.assetId, r.providerId, r.amountUg, requestId);
        }
    }

    function finalizeBuy(
        StoexTypes.TradeRequest storage r,
        uint256 requestId,
        address user,
        bytes32 assetId,
        bytes32 providerId,
        uint256 weightUg,
        uint256 fiat_value,
        bytes32 payment_ref,
        bytes32 txDetailsHash_,
        DayCaps storage caps,
        mapping(address => uint256) storage nonKycFiatPurchased,
        IWhitelistRegistry whitelistRegistry,
        IGovernanceConfig governance,
        IAssetLedger assetLedger
    ) external {
        if (assetLedger.tokenIdByBeneficiary(user, assetId) == 0) {
            assetLedger.mintCertificateForTrade(assetId, user);
        }
        assetLedger.transferFromAPToUser(assetId, providerId, user, weightUg, emptyLot(), requestId, StoexTypes.TxType.Buy);

        if (whitelistRegistry.isEligible(user)) {
            _accrueBuy(caps, assetId, weightUg);
        } else {
            nonKycFiatPurchased[user] += fiat_value;
        }

        uint256 exp = block.timestamp + governance.requestExpiryDuration();
        r.assetId = assetId;
        r.providerId = providerId;
        r.requestType = StoexTypes.RequestType.Buy;
        r.status = StoexTypes.RequestStatus.Executed;
        r.initiator = user;
        r.targetUser = user;
        r.amountUg = weightUg;
        r.paymentRefId = payment_ref;
        r.vaultReceiptId = bytes32(0);
        r.reason = "";
        r.createdAt = block.timestamp;
        r.expiresAt = exp;
        r.approvalsDone = 0;
        r.mintLot = emptyLot();
        r.escrowLocked = false;
        r.fiatValue = fiat_value;
        r.txDetailsHash = txDetailsHash_;
    }

    function verifyCoSigners(
        bytes32 digest,
        bytes[] calldata signatures,
        bytes32[] memory pol,
        bytes32 providerId,
        IAccessControl roles,
        IAssetProviderRegistry assetProviderRegistry
    ) external view {
        address last = address(0);
        for (uint256 i = 0; i < pol.length; i++) {
            address signer = ECDSA.recover(digest, signatures[i]);
            if (signer == last) revert DuplicateSigner();
            if (!roles.hasRole(pol[i], signer)) revert BadSigner();
            if (pol[i] == StoexRoles.AP_ROLE && !assetProviderRegistry.isOperator(providerId, signer)) {
                revert BadSigner();
            }
            last = signer;
        }
    }

    function requireNotTimelocked(
        address user,
        bytes32 assetId,
        ITimelockController timelockController,
        IAssetLedger assetLedger
    ) external view {
        if (timelockController.isTimelocked(user)) revert Timelocked();
        uint256[] memory lots = assetLedger.getUserLotIds(user, assetId);
        for (uint256 i = 0; i < lots.length; i++) {
            uint256 exp = timelockController.getLotTimelockExpiry(lots[i]);
            if (exp != 0 && block.timestamp < exp) revert Timelocked();
        }
    }

    function emptyLot() public pure returns (StoexTypes.MintLotMeta memory m) {
        return m;
    }

    function _checkSellCap(DayCaps storage caps, IGovernanceConfig governance, bytes32 assetId, uint256 amountUg)
        private
        view
    {
        uint256 day = block.timestamp / 1 days;
        uint256 used = caps.sellDay[assetId] == day ? caps.sellDayAmountUg[assetId] : 0;
        if (used + amountUg > governance.dailySellCap(assetId)) revert CapSell();
    }

    function _accrueBuy(DayCaps storage caps, bytes32 assetId, uint256 amountUg) private {
        uint256 day = block.timestamp / 1 days;
        if (caps.buyDay[assetId] != day) {
            caps.buyDay[assetId] = day;
            caps.buyDayAmountUg[assetId] = 0;
        }
        caps.buyDayAmountUg[assetId] += amountUg;
    }

    function _accrueSell(DayCaps storage caps, bytes32 assetId, uint256 amountUg) private {
        uint256 day = block.timestamp / 1 days;
        if (caps.sellDay[assetId] != day) {
            caps.sellDay[assetId] = day;
            caps.sellDayAmountUg[assetId] = 0;
        }
        caps.sellDayAmountUg[assetId] += amountUg;
    }

    error NotEligible();
    error CapSell();
    error Timelocked();
    error BadSigner();
    error DuplicateSigner();
}
