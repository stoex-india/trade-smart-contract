// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

import {GovernanceConfig} from "../../src/GovernanceConfig.sol";
import {WhitelistRegistry} from "../../src/WhitelistRegistry.sol";
import {AssetLedger} from "../../src/AssetLedger.sol";
import {AssetRegistry} from "../../src/AssetRegistry.sol";
import {AssetProviderRegistry} from "../../src/AssetProviderRegistry.sol";
import {EscrowVault} from "../../src/EscrowVault.sol";
import {TimelockController} from "../../src/TimelockController.sol";
import {TradeManager} from "../../src/TradeManager.sol";
import {StoexRoles} from "../../src/libraries/StoexRoles.sol";
import {StoexTypes} from "../../src/libraries/StoexTypes.sol";
import {StoexIds} from "../../src/libraries/StoexIds.sol";

/// @dev Shared UUPS deployment + wiring for STOEX multi-asset integration tests.
abstract contract StoexFixture is Test {
    GovernanceConfig internal gov;
    WhitelistRegistry internal registry;
    AssetRegistry internal assetReg;
    AssetProviderRegistry internal providerReg;
    AssetLedger internal ledger;
    EscrowVault internal escrow;
    TimelockController internal timelock;
    TradeManager internal trade;

    bytes32 internal constant GOLD = StoexIds.GOLD;
    bytes32 internal constant SILVER = StoexIds.SILVER;
    bytes32 internal constant AP1 = keccak256("AP1");
    bytes32 internal constant AP2 = keccak256("AP2");

    address internal admin;
    address internal ap;
    address internal ap2;
    address internal vp;
    address internal at;
    address internal pap;
    address internal auditor;
    address internal user;
    address internal payoutAp1;
    address internal payoutAp2;
    address internal redeemAp1;
    address internal redeemAp2;

    uint256 internal apKey;
    uint256 internal vpKey;
    uint256 internal atKey;
    address internal forwarder;

    function setUp() public virtual {
        admin = address(this);
        address deployer = address(this);
        (ap, apKey) = makeAddrAndKey("ap");
        ap2 = makeAddr("ap2");
        (vp, vpKey) = makeAddrAndKey("vp");
        (at, atKey) = makeAddrAndKey("at");
        pap = makeAddr("pap");
        auditor = makeAddr("auditor");
        user = makeAddr("user");
        payoutAp1 = makeAddr("payoutAp1");
        payoutAp2 = makeAddr("payoutAp2");
        redeemAp1 = makeAddr("redeemAp1");
        redeemAp2 = makeAddr("redeemAp2");
        forwarder = address(new ERC2771Forwarder("STOEX Forwarder (Test)"));

        address govAddr;
        {
            GovernanceConfig impl = new GovernanceConfig();
            govAddr = address(new ERC1967Proxy(address(impl), abi.encodeCall(GovernanceConfig.initialize, (deployer))));
        }
        gov = GovernanceConfig(govAddr);

        address regAddr;
        {
            WhitelistRegistry impl = new WhitelistRegistry();
            regAddr = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(WhitelistRegistry.initialize, (deployer, forwarder)))
            );
        }
        registry = WhitelistRegistry(regAddr);

        address assetRegAddr;
        {
            AssetRegistry impl = new AssetRegistry();
            assetRegAddr = address(new ERC1967Proxy(address(impl), abi.encodeCall(AssetRegistry.initialize, (deployer))));
        }
        assetReg = AssetRegistry(assetRegAddr);

        address providerRegAddr;
        {
            AssetProviderRegistry impl = new AssetProviderRegistry();
            providerRegAddr = address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(AssetProviderRegistry.initialize, (deployer, assetRegAddr))
                )
            );
        }
        providerReg = AssetProviderRegistry(providerRegAddr);

        address ledgerAddr;
        {
            AssetLedger impl = new AssetLedger();
            ledgerAddr = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(AssetLedger.initialize, (deployer, regAddr, forwarder)))
            );
        }
        ledger = AssetLedger(ledgerAddr);

        address escrowAddr;
        {
            EscrowVault impl = new EscrowVault();
            escrowAddr = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(EscrowVault.initialize, (deployer, ledgerAddr)))
            );
        }
        escrow = EscrowVault(escrowAddr);

        address timelockAddr;
        {
            TimelockController impl = new TimelockController();
            timelockAddr = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(TimelockController.initialize, (deployer)))
            );
        }
        timelock = TimelockController(timelockAddr);

        address tradeAddr;
        {
            TradeManager impl = new TradeManager();
            tradeAddr = address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        TradeManager.initialize,
                        (deployer, govAddr, regAddr, ledgerAddr, escrowAddr, timelockAddr, assetRegAddr, providerRegAddr, forwarder)
                    )
                )
            );
        }
        trade = TradeManager(tradeAddr);

        gov.setInitialAdmin(admin);
        registry.setInitialAdmin(admin);
        ledger.setInitialAdmin(admin);
        escrow.setInitialAdmin(admin);
        timelock.setInitialAdmin(admin);
        trade.setInitialAdmin(admin);
        assetReg.setInitialAdmin(admin);
        providerReg.setInitialAdmin(admin);

        assetReg.registerAsset(GOLD, "AU", "Gold", 6);
        assetReg.registerAsset(SILVER, "AG", "Silver", 6);
        _setupProvider(AP1, "Provider One", ap, payoutAp1, redeemAp1, true, true);
        _setupProvider(AP2, "Provider Two", ap2, payoutAp2, redeemAp2, true, true);

        escrow.setTradeManager(tradeAddr);
        timelock.setTradeManager(tradeAddr);
        ledger.grantRole(StoexRoles.TRADE_MANAGER_ROLE, tradeAddr);
        registry.setTradeManager(tradeAddr);

        trade.grantRole(StoexRoles.AP_ROLE, ap);
        trade.grantRole(StoexRoles.AP_ROLE, ap2);
        trade.grantRole(StoexRoles.VP_ROLE, vp);
        trade.grantRole(StoexRoles.AT_ROLE, at);
        trade.grantRole(StoexRoles.PAP_ROLE, pap);
        trade.grantRole(StoexRoles.AUDITOR_ROLE, auditor);

        ledger.grantRole(StoexRoles.AP_ROLE, ap);
        ledger.grantRole(StoexRoles.AP_ROLE, ap2);

        timelock.grantRole(StoexRoles.AP_ROLE, ap);
        timelock.grantRole(StoexRoles.AP_ROLE, ap2);
        timelock.grantRole(StoexRoles.AT_ROLE, at);

        gov.grantRole(StoexRoles.AT_ROLE, at);
        registry.grantRole(StoexRoles.AT_ROLE, at);

        _registerVerifiedUser(user);

        _mintPoolInventory(GOLD, AP1, ap, 10_000_000_000);
        _mintPoolInventory(SILVER, AP2, ap2, 5_000_000_000);
    }

    function _setupProvider(
        bytes32 providerId,
        string memory name,
        address operator,
        address payout,
        address redeem,
        bool gold,
        bool silver
    ) internal {
        providerReg.registerProvider(providerId, name);
        providerReg.addProviderOperator(providerId, operator);
        if (gold) {
            providerReg.setProviderAsset(providerId, GOLD, true);
            providerReg.setAssetRouting(providerId, GOLD, payout, redeem);
        }
        if (silver) {
            providerReg.setProviderAsset(providerId, SILVER, true);
            providerReg.setAssetRouting(providerId, SILVER, payout, redeem);
        }
    }

    function _mintPoolInventory(bytes32 assetId, bytes32 providerId, address ap_, uint256 amountUg) internal {
        uint256 maxPerTx = gov.maxAmountPerTx();
        StoexTypes.MintLotMeta memory lot = StoexTypes.MintLotMeta({
            assetId: assetId,
            providerId: providerId,
            vaultReceiptId: bytes32(uint256(1)),
            batchId: bytes32(uint256(2)),
            purity: 9999,
            depositTimestamp: block.timestamp,
            vpId: vp,
            lockUntilTs: 0,
            amountUg: 0
        });
        uint256 remaining = amountUg;
        while (remaining > 0) {
            uint256 chunk = remaining > maxPerTx ? maxPerTx : remaining;
            vm.prank(forwarder);
            uint256 rid = trade.proposeMintFor(ap_, assetId, providerId, chunk, bytes32(uint256(3)), lot);
            vm.prank(forwarder);
            trade.approveRequestFor(vp, rid);
            vm.prank(forwarder);
            trade.approveRequestFor(at, rid);
            trade.executeRequest(rid);
            remaining -= chunk;
        }
    }

    function _registerVerifiedUser(address u) internal {
        registry.adminRegisterUser(keccak256(abi.encodePacked("u", u)), u, "kyc");
        vm.prank(forwarder);
        registry.verifyKYCFor(u);
    }

    function _registerPendingKycUser(address u) internal {
        registry.adminRegisterUser(keccak256(abi.encodePacked("p", u)), u, "kyc");
    }

    function _executeBuy(address investor, bytes32 assetId, bytes32 providerId, uint256 amountUg)
        internal
        returns (uint256 requestId)
    {
        vm.prank(forwarder);
        requestId = trade.createBuyRequestFor(
            investor, assetId, providerId, amountUg, _defaultFiat(amountUg), bytes32(uint256(1)), bytes32(uint256(2))
        );
    }

    function _sellRequest(address investor, bytes32 assetId, bytes32 providerId, uint256 amountUg, bytes32 payoutRef)
        internal
        returns (uint256 requestId)
    {
        vm.prank(forwarder);
        return trade.createSellRequestFor(investor, assetId, providerId, amountUg, payoutRef);
    }

    function _redeemRequest(address investor, bytes32 assetId, bytes32 providerId, uint256 amountUg, bytes32 deliveryRef)
        internal
        returns (uint256 requestId)
    {
        vm.prank(forwarder);
        return trade.createRedeemRequestFor(investor, assetId, providerId, amountUg, deliveryRef);
    }

    function _approveRequest(address approver, uint256 requestId) internal {
        vm.prank(forwarder);
        trade.approveRequestFor(approver, requestId);
    }

    function _rejectRequest(address rejector, uint256 requestId, string memory reason) internal {
        vm.prank(forwarder);
        trade.rejectRequestFor(rejector, requestId, reason);
    }

    function _cancelRequest(address initiator, uint256 requestId) internal {
        vm.prank(forwarder);
        trade.cancelRequestFor(initiator, requestId);
    }

    function _proposeMint(
        address ap_,
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        bytes32 vaultReceiptId,
        StoexTypes.MintLotMeta memory lot
    ) internal returns (uint256 requestId) {
        vm.prank(forwarder);
        return trade.proposeMintFor(ap_, assetId, providerId, amountUg, vaultReceiptId, lot);
    }

    function _proposeBurn(
        address ap_,
        bytes32 assetId,
        bytes32 providerId,
        uint256 amountUg,
        bytes32 referenceId,
        string memory reason_
    ) internal returns (uint256 requestId) {
        vm.prank(forwarder);
        return trade.proposeBurnFor(ap_, assetId, providerId, amountUg, referenceId, reason_);
    }

    function _defaultFiat(uint256 amountUg) internal pure returns (uint256) {
        return amountUg * 100;
    }

    function _packSig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
