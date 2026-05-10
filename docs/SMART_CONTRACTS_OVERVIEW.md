# STOEX Smart Contracts Overview

This document introduces each core contract and summarizes its external/public read and write endpoints.

## System Architecture (High Level)

- `TradeManager` is the central orchestrator for user and operator trade flows.
- `GoldNFT` tracks certificate ownership and gold balances (in mg).
- `WhitelistRegistry` gates eligibility and wallet risk/compliance state.
- `GovernanceConfig` stores configurable policy limits, role-approval policy, and thresholds.
- `EscrowVault` locks/unlocks user balances for sell/redeem lifecycle.
- `TimelockController` enforces wallet/lot timelocks.

Most operational writes are role-gated via AccessControl roles defined in `StoexRoles`.

---

## `TradeManager`

Purpose: trade request lifecycle controller. Buy is auto-finalized in `createBuyRequest`; other request types use propose -> approvals -> execution.

### Key Read Endpoints

- `trustedForwarder()`: returns current ERC-2771 trusted forwarder address.
- `getRequest(uint256 requestId)`: full request struct details.
- `getRequestStatus(uint256 requestId)`: current status enum for a request.
- `hashCoSignBatch(uint256 requestId,uint256 nonce,uint256 deadline)`: EIP-712 digest helper for co-sign execution.
- `getUserRequests(address user,uint256 offset,uint256 limit)`: paginated request IDs for user.
- `coSignNonce(uint256 requestId)`: nonce used in `executeWithCoSignatures`.

### Key Write Endpoints

- `setTrustedForwarder(address)`: admin updates trusted forwarder.
- `setRoutingAddresses(address assetProviderPayout,address redeemSink,address vaultBookkeeping)`: one-time routing setup.
- `pause()/unpause()`: admin pause controls.
- `createBuyRequest(uint256 weightMg,uint256 fiat_value,bytes32 payment_ref,bytes32 txDetailsHash)`: user buy (auto-exec).
- `createSellRequest(uint256 grams,bytes32 payoutRefId)`: user sell request creation.
- `createRedeemRequest(uint256 grams,bytes32 deliveryRefId)`: user redeem request creation.
- `proposeMint(uint256 grams,address creditTo,bytes32 vaultReceiptId,(...lot))`: AP mint proposal.
- `proposeBurn(uint256 grams,bytes32 referenceId,string reason_)`: AP burn proposal.
- `approveRequest(uint256 requestId)`: role-based approvals.
- `rejectRequest(uint256 requestId,string reason_)`: reject + optional escrow unlock.
- `cancelRequest(uint256 requestId)`: initiator cancel while pending.
- `expireRequest(uint256 requestId)`: mark expired after TTL.
- `executeRequest(uint256 requestId)`: admin executes non-buy requests.
- `executeWithCoSignatures(uint256 requestId,uint256 nonce,uint256 deadline,bytes[] signatures)`: batched co-sign execution path.

Notes:
- Buy uses immediate execution path and does not go through `executeRequest`.
- Amount units in this contract are mg (milligrams), even where variable names still use `grams`.

---

## `GoldNFT`

Purpose: certificate NFT + inventory/accounting ledger for user holdings and AP pool holdings.

### Key Read Endpoints

- `trustedForwarder()`: ERC-2771 trusted forwarder.
- `getUserHolding(address user)`: user holding in mg.
- `getMintLot(uint256 lotId)`: mint lot metadata.
- `getUserLotIds(address beneficiary)`: lot IDs linked to wallet.
- `getTxHistory(address user,uint256 start,uint256 end)`: tx history slice.
- `circulatingSupply()`: `totalGoldSupply - totalAssetProviderBalance`.
- `totalGoldSupply()`, `totalAssetProviderBalance()`, `userHolding(address)`, `tokenIdByBeneficiary(address)`, `beneficiaryOfToken(uint256)`.

### Key Write Endpoints

- `setTrustedForwarder(address)`: admin.
- `setWhitelistRegistry(address)`: admin updates registry dependency.
- `setBaseURI(string)`: admin metadata base URI.
- `mintCertificate(address user)`: AP mint certificate.
- `mintCertificateForTrade(address user)`: trade manager mint cert helper.
- `increaseSupply(address user,uint256 grams,...)`: trade manager supply increase.
- `decreaseSupply(address user,uint256 grams,...)`: trade manager supply decrease.
- `transferFromAPToUser(address user,uint256 grams,...)`: trade manager pool -> user transfer for buy.
- `updateMetadata(uint256 tokenId,string newUri)`: admin metadata update.
- `nomineeTransfer(address fromBeneficiary,address toCustody)`: admin emergency/custody transfer.
- `seedPoolInventory(uint256 grams)`: admin adds AP pool inventory.
- `pause()/unpause()`: admin.

---

## `GovernanceConfig`

Purpose: policy and limits configuration contract used by `TradeManager`.

### Key Read Endpoints

- `getApprovalPolicy(RequestType)`: ordered role approvals.
- `requestExpiryDuration()`: request timeout window.
- `dailyBuyCap()`, `dailySellCap()`: per-day caps.
- `minRedeemQuantity()`: minimum redeem amount.
- `maxGramsPerTx()`: max amount per request.
- `defaultTimelockDuration()`: default timelock for lots/wallets.
- `goldPrecision()`: precision metadata.
- `nonKycMaxBuyFiatAmount()`: per-user cumulative fiat cap for non-KYC buy.
- `minimumBuyGoldValueInMg()`: minimum buy threshold in mg.
- `vpRequiredForApprovals()`: whether VP is mandatory where optional.

### Key Write Endpoints

- `setVpRequiredForApprovals(bool)`: admin.
- `setNonKycMaxBuyFiatAmount(uint256)`: AT role.
- `setMinimumBuyGoldValueInMg(uint256)`: admin.
- `setApprovalPolicy(RequestType,bytes32[] roles)`: AT role.
- `setDailyCap(RequestType,uint256)`: AT role.
- `setMinRedeemQuantity(uint256)`: AT role.
- `setRequestExpiry(uint256)`: AT role.
- `setMaxGramsPerTx(uint256)`: AT role.
- `setDefaultTimelockDuration(uint256)`: AT role.
- `setGoldPrecision(uint8)`: AT role.

---

## `WhitelistRegistry`

Purpose: identity/KYC/eligibility/risk management for wallets.

### Key Read Endpoints

- `trustedForwarder()`: ERC-2771 trusted forwarder.
- `isEligible(address wallet)`: full eligibility (KYC + whitelist + no blocks/suspension).
- `isEligibleForNonKycUser(address wallet)`: non-KYC limited-eligibility path.
- `getProfile(address wallet)`: complete profile struct.

### Key Write Endpoints

- `setTrustedForwarder(address)`: admin.
- `registerUser(bytes32 userId,address wallet,string kycRef)`: admin register profile.
- `verifyKYC(address wallet)`: admin.
- `rejectKYC(address wallet)`: admin.
- `whitelistWallet(address wallet)`: admin.
- `requestWalletChange(address oldWallet,address newWallet)`: user requests migration.
- `approveWalletChange(uint256 changeRequestId)`: AP/AT approval path.
- `suspendWallet(address wallet,bytes32 caseRef)`: admin.
- `blacklistWallet(address wallet,bytes32 caseRef)`: admin.
- `setWalletRisk(address wallet,RiskLevel,bytes32 caseRef)`: admin.
- `setUserBlocked(address wallet,bool blocked)`: admin.
- `unsuspendWallet(address wallet,bytes32 caseRef)`: AT role.

---

## `EscrowVault`

Purpose: lock and release user balances for sell/redeem workflows.

### Key Read Endpoints

- `getLockedAmount(address wallet)`: current locked amount.
- `getAvailableBalance(address wallet)`: user holding minus locked.
- `getEscrowDetails(uint256 requestId)`: escrow details for request.

### Key Write Endpoints

- `setTradeManager(address)`: admin sets trade manager once.
- `lockTokens(address wallet,uint256 grams,EscrowReason,uint256 requestId)`: trade manager locks.
- `unlockTokens(uint256 requestId)`: trade manager unlocks.
- `releaseEscrow(uint256 requestId,address destination)`: trade manager final release destination.

---

## `TimelockController`

Purpose: timelock enforcement on wallets/lots to prevent premature sell/redeem.

### Key Read Endpoints

- `getTimelockStatus(address wallet)`: wallet lock status + expiry.
- `getLotTimelockStatus(uint256 lotId)`: lot lock status + expiry.
- `getLotTimelockExpiry(uint256 lotId)`: lot expiry timestamp.
- `isWalletTimelockedUntil(address wallet)`: wallet lock expiry ts.
- `isTimelocked(address wallet)`: boolean wallet lock check.

### Key Write Endpoints

- `setTradeManager(address)`: admin sets trade manager.
- `applyMintLotTimelock(uint256 lotId,uint256 untilTs)`: trade manager lot lock.
- `setWalletTimelock(address wallet,uint256 untilTs)`: AP role wallet lock.
- `setLotTimelock(uint256 lotId,uint256 untilTs)`: AP role lot lock.
- `overrideTimelock(address wallet,uint256 requestId)`: AT override.
- `overrideLotTimelock(uint256 lotId,uint256 requestId)`: AT override.

---

## Common Integration Notes

- ERC-2771 is used in user-facing contracts (`TradeManager`, `GoldNFT`, `WhitelistRegistry`).
- Set trusted forwarder to Tresori gasless forwarder/relayer contract via `RELAYER_SMART_CONTRACT` and `script/SetTrustedForwarder.s.sol`.
- User/client gasless writes should use Tresori SDK `writeGaslessMpcSmartContractTransaction(...)`.
- Check roles before calling write methods; many methods revert when caller lacks required role.
- Keep amount units consistent (mg) across UI payloads and contract calls.
