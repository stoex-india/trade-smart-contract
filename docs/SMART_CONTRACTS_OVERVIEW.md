# STOEX Smart Contracts Overview

``` 
GOVERNANCE_CONFIG=0xaDECBd9A1968058dF59f5E68432986829C16E1e1
WHITELIST_REGISTRY=0x4093F539F2f2857931bbAB1E67d0A9ceE8Ef2CCC
GOLD_NFT=0xCa3253F4A78cFe275B15db5Cb3645d5BEAC16215
ESCROW_VAULT=0xb9D55b7f8B2A4C79dC85C4C80e6EBB4e514bdf1F
TIMELOCK_CONTROLLER=0xF9dCc93BAFB69B596f08C66601dA8efD9D42a26E
TRADE_MANAGER=0xDa75Fd41DB3d859f15ED6153A78f246C4fCC48F9 
```

This document introduces each core contract and summarizes its external/public read and write endpoints.

## System Architecture (High Level)

- `TradeManager` is the central orchestrator for user and operator trade flows.
- `GoldNFT` tracks certificate ownership and gold balances (in **µg**).
- `WhitelistRegistry` gates eligibility and wallet risk/compliance state.
- `GovernanceConfig` stores configurable policy limits, role-approval policy, and thresholds.
- `EscrowVault` locks/unlocks user balances for sell/redeem lifecycle.
- `TimelockController` enforces wallet/lot timelocks.

Most operational writes are role-gated via AccessControl roles defined in `StoexRoles`.

**Gold unit:** all on-chain gold quantities are **integer micrograms (µg)**. `1 gram = 1_000_000 µg`. There is no fractional type on-chain; use `amountUg` fields consistently. Redeploy fresh proxies when upgrading; no in-repo storage migration.

---

## `TradeManager`

Purpose: trade request lifecycle controller. Buy is auto-finalized in `createBuyRequestFor`; other request types use propose → approvals → execution.

### Key Read Endpoints

- `trustedForwarder()`: returns current ERC-2771 trusted forwarder address.
- `getRequest(uint256 requestId)`: full request struct (`amountUg`, status, mint lot, etc.).
- `getRequestStatus(uint256 requestId)`: current status enum for a request.
- `hashCoSignBatch(uint256 requestId,uint256 nonce,uint256 deadline)`: EIP-712 digest helper for co-sign execution.
- `getUserRequests(address user,uint256 offset,uint256 limit)`: paginated request IDs for user.
- `coSignNonce(uint256 requestId)`: nonce used in `executeWithCoSignatures`.

### Key Write Endpoints

- `setTrustedForwarder(address)`: admin updates trusted forwarder.
- `setRoutingAddresses(address assetProviderPayout,address redeemSink,address vaultBookkeeping)`: one-time routing setup.
- `pause()/unpause()`: admin pause controls.
- `createBuyRequestFor(address user, ...)`: gasless user buy (auto-exec).
- `createSellRequestFor(address user, ...)`: gasless user sell request.
- `createRedeemRequestFor(address user, ...)`: gasless user redeem request.
- `proposeMintFor(address ap, ...)`, `proposeBurnFor(address ap, ...)`: gasless AP proposals.
- `approveRequestFor(address approver, uint256 requestId)`: gasless role-based approvals.
- `createRedeemRequest(uint256 amountUg,bytes32 deliveryRefId)`: user redeem request creation.
- `proposeMint(uint256 amountUg,address creditTo,bytes32 vaultReceiptId,MintLotMeta lot)`: AP mint proposal.
- `proposeBurn(uint256 amountUg,bytes32 referenceId,string reason_)`: AP burn proposal.
- `rejectRequest(uint256 requestId,string reason_)`: reject + optional escrow unlock.
- `cancelRequest(uint256 requestId)`: initiator cancel while pending.
- `expireRequest(uint256 requestId)`: mark expired after TTL.
- `executeRequest(uint256 requestId)`: admin executes non-buy requests.
- `executeWithCoSignatures(uint256 requestId,uint256 nonce,uint256 deadline,bytes[] signatures)`: batched co-sign execution path.

Notes:

- Buy uses immediate execution path and does not go through `executeRequest`.
- All amount parameters and `TradeRequest.amountUg` are in **µg**.

---

## `GoldNFT`

Purpose: certificate NFT + inventory/accounting ledger for user holdings and AP pool holdings.

### Key Read Endpoints

- `trustedForwarder()`: ERC-2771 trusted forwarder.
- `userHolding(address user)`: user balance in µg.
- `getMintLot(uint256 lotId)`: mint lot metadata (`MintLotMeta.amountUg`).
- `getUserLotIds(address beneficiary)`: lot IDs linked to wallet.
- `getTxHistory(address user,uint256 start,uint256 end)`: tx history slice (`TxRecord.amountUg`).
- `circulatingSupply()`: `totalGoldSupply - totalAssetProviderBalance`.
- `totalGoldSupply()`, `totalAssetProviderBalance()`, `tokenIdByBeneficiary(address)`, `beneficiaryOfToken(uint256)`.

### Key Write Endpoints

- `setTrustedForwarder(address)`: admin.
- `setWhitelistRegistry(address)`: admin updates registry dependency.
- `setBaseURI(string)`: admin metadata base URI.
- `mintCertificate(address user)`: AP mint certificate.
- `mintCertificateForTrade(address user)`: trade manager mint cert helper.
- `increaseSupply(address user,uint256 amountUg,...)`: trade manager supply increase.
- `decreaseSupply(address user,uint256 amountUg,...)`: trade manager supply decrease.
- `transferFromAPToUser(address user,uint256 amountUg,...)`: trade manager pool → user transfer for buy.
- `updateMetadata(uint256 tokenId,string newUri)`: admin metadata update.
- `nomineeTransfer(address fromBeneficiary,address toCustody)`: admin emergency/custody transfer.
- `seedPoolInventory(uint256 amountUg)`: admin adds AP pool inventory (µg).
- `pause()/unpause()`: admin.

---

## `GovernanceConfig`

Purpose: policy and limits configuration contract used by `TradeManager`. All gold caps/limits are **µg**.

### Key Read Endpoints

- `getApprovalPolicy(RequestType)`: ordered role approvals.
- `requestExpiryDuration()`: request timeout window.
- `dailyBuyCap()`, `dailySellCap()`: per-day caps (µg).
- `minRedeemAmountUg()`: minimum redeem amount (µg).
- `maxAmountPerTx()`: max amount per request (µg).
- `defaultTimelockDuration()`: default timelock for lots/wallets.
- `goldPrecision()`: off-chain decimal places when displaying grams (default `6`).
- `nonKycMaxBuyFiatAmount()`: per-user cumulative fiat cap for non-KYC buy.
- `minimumBuyGoldValueInUg()`: minimum buy threshold (µg).
- `vpRequiredForApprovals()`: whether VP is mandatory where optional.

### Key Write Endpoints

- `setVpRequiredForApprovals(bool)`: admin.
- `setNonKycMaxBuyFiatAmount(uint256)`: AT role.
- `setMinimumBuyGoldValueInUg(uint256)`: admin.
- `setApprovalPolicy(RequestType,bytes32[] roles)`: AT role.
- `setDailyCap(RequestType,uint256)`: AT role (cap in µg).
- `setMinRedeemAmountUg(uint256)`: AT role.
- `setRequestExpiry(uint256)`: AT role.
- `setMaxAmountPerTx(uint256)`: AT role.
- `setDefaultTimelockDuration(uint256)`: AT role.
- `setGoldPrecision(uint8)`: AT role.

Default init examples: `minimumBuyGoldValueInUg = 1000` (1 mg), `minRedeemAmountUg = 10_000_000` (10 g), `maxAmountPerTx = 1_000_000_000` (1 kg).

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
- `registerUserFor(address wallet, bytes32 userId, string kycRef)`: gasless self-registration via relayer.
- `adminRegisterUser(bytes32 userId, address wallet, string kycRef)`: admin back-office registration.
- `verifyKYC(address wallet)`: admin.
- `rejectKYC(address wallet)`: admin.
- `whitelistWallet(address wallet)`: admin.
- `requestWalletChange(address oldWallet,address newWallet)`: user requests wallet change.
- `approveWalletChange(uint256 changeRequestId)`: AP/AT approval path.
- `suspendWallet(address wallet,bytes32 caseRef)`: admin.
- `blacklistWallet(address wallet,bytes32 caseRef)`: admin.
- `setWalletRisk(address wallet,RiskLevel,bytes32 caseRef)`: admin.
- `setUserBlocked(address wallet,bool blocked)`: admin.
- `unsuspendWallet(address wallet,bytes32 caseRef)`: AT role.

---

## `EscrowVault`

Purpose: lock and release user balances for sell/redeem workflows (amounts in µg).

### Key Read Endpoints

- `getLockedAmount(address wallet)`: current locked amount (µg).
- `getAvailableBalance(address wallet)`: user holding minus locked.
- `getEscrowDetails(uint256 requestId)`: escrow details (`amountUg`).

### Key Write Endpoints

- `setTradeManager(address)`: admin sets trade manager once.
- `lockTokens(address wallet,uint256 amountUg,EscrowReason,uint256 requestId)`: trade manager locks.
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
- Keep amount units consistent (**µg**) across UI payloads and contract calls; convert to grams only for display.
