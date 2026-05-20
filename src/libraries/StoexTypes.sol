// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title STOEX Gold — StoexTypes
/// @notice Shared **enums** and **structs** for the STOEX India Gold tokenization EVM stack (PRD v2.0).
/// @dev Used by `TradeManager`, `GoldNFT`, `WhitelistRegistry`, and interfaces. Request lifecycle enums mirror the PRD; `PAPApproved` models the Physical Asset Provider step on redeem.
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
        bytes32 vaultReceiptId;
        bytes32 batchId;
        uint16 purity;
        uint256 depositTimestamp;
        address apId;
        address vpId;
        uint256 lockUntilTs;
        uint256 amountUg;
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
        TxType txType;
        uint256 amountUg;
        uint256 timestamp;
        uint256 requestId;
    }
}
