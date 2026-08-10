// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StoexTypes} from "./StoexTypes.sol";
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
        IEscrowVault escrowVault
    ) external {
        if (r.requestType == StoexTypes.RequestType.Sell) {
            if (!whitelistRegistry.isEligible(r.targetUser)) revert NotEligible();
            _checkSellCap(caps, governance, r.assetId, r.amountUg);
            _accrueSell(caps, r.assetId, r.amountUg);
            address payout = assetProviderRegistry.getSellPayout(r.providerId, r.assetId);
            escrowVault.releaseEscrow(requestId, payout);
            r.escrowLocked = false;
            assetLedger.decreaseSupply(
                r.assetId, r.providerId, r.targetUser, r.amountUg, StoexTypes.TxType.Sell, requestId
            );
        } else if (r.requestType == StoexTypes.RequestType.Redeem) {
            if (!whitelistRegistry.isEligible(r.targetUser)) revert NotEligible();
            address sink = assetProviderRegistry.getRedeemSink(r.providerId, r.assetId);
            escrowVault.releaseEscrow(requestId, sink);
            r.escrowLocked = false;
            assetLedger.decreaseSupply(
                r.assetId, r.providerId, r.targetUser, r.amountUg, StoexTypes.TxType.Redeem, requestId
            );
        } else {
            revert UnsupportedRequestType();
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
        mapping(bytes32 => uint256) storage nonKycFiatPurchasedByUserId,
        IWhitelistRegistry whitelistRegistry,
        IGovernanceConfig governance,
        IAssetLedger assetLedger
    ) external {
        if (assetLedger.tokenIdByBeneficiary(user, assetId) == 0) {
            assetLedger.mintCertificateForTrade(assetId, user);
        }
        assetLedger.creditUserBuy(assetId, providerId, user, weightUg, requestId);

        if (whitelistRegistry.isEligible(user)) {
            _accrueBuy(caps, assetId, weightUg);
        } else {
            bytes32 userId = whitelistRegistry.getProfile(user).userId;
            nonKycFiatPurchasedByUserId[userId] += fiat_value;
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

    function requireNotTimelocked(address user, bytes32 assetId, ITimelockController timelockController)
        external
        view
    {
        if (timelockController.isTimelocked(user)) revert Timelocked();
        if (timelockController.isUserAssetLotTimelocked(user, assetId)) revert Timelocked();
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
    error UnsupportedRequestType();
}
