// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — StoexTypes
/// @notice Shared **enums** and **structs** for the STOEX India Gold tokenization EVM stack (PRD v2.0).
/// @dev Used by `TradeManager`, `AssetLedger`, `WhitelistRegistry`, and interfaces.
library StoexTypes {
    enum KYCStatus {
        Pending,
        Verified,
        Rejected
    }

    enum WalletStatus {
        Whitelisted,
        Suspended,
        Blacklisted
    }

    enum UserStatus {
        Active,
        Blocked
    }

    enum RiskLevel {
        Low,
        Medium,
        High,
        Flagged,
        Suspended
    }

    enum RequestType {
        Buy,
        Sell,
        Redeem,
        Mint,
        Burn
    }

    /// @dev PRD statuses; PAPApproved covers Physical Asset Provider step on redeem.
    enum RequestStatus {
        Proposed,
        APApproved,
        VPApproved,
        PAPApproved,
        ATApproved,
        Executed,
        Rejected,
        Expired,
        Cancelled
    }

    enum EscrowReason {
        Sell,
        Redeem
    }

    enum TxType {
        Buy,
        Sell,
        Redeem,
        Mint,
        Burn,
        Adjustment
    }

    struct MintLotMeta {
        bytes32 assetId;
        bytes32 providerId;
        bytes32 vaultReceiptId;
        bytes32 batchId;
        uint16 purity;
        uint256 depositTimestamp;
        address vpId;
        uint256 lockUntilTs;
        uint256 amountUg;
    }

    struct AssetConfig {
        string symbol;
        string name;
        bool active;
        bool registered;
        uint8 precision;
    }

    struct UserProfile {
        bytes32 userId;
        address wallet;
        KYCStatus kycStatus;
        WalletStatus walletStatus;
        UserStatus userStatus;
        RiskLevel riskLevel;
        string kycRef;
        uint256 registeredAt;
    }

    struct TxRecord {
        bytes32 assetId;
        bytes32 providerId;
        TxType txType;
        uint256 amountUg;
        uint256 timestamp;
        uint256 requestId;
    }

    struct TradeRequest {
        bytes32 assetId;
        bytes32 providerId;
        RequestType requestType;
        RequestStatus status;
        address initiator;
        address targetUser;
        uint256 amountUg;
        bytes32 paymentRefId;
        bytes32 vaultReceiptId;
        string reason;
        uint256 createdAt;
        uint256 expiresAt;
        uint256 approvalsDone;
        MintLotMeta mintLot;
        bool escrowLocked;
        uint256 fiatValue;
        bytes32 txDetailsHash;
    }
}
