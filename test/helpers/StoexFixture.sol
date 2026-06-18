// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

import {GovernanceConfig} from "../../src/GovernanceConfig.sol";
import {WhitelistRegistry} from "../../src/WhitelistRegistry.sol";
import {GoldNFT} from "../../src/GoldNFT.sol";
import {EscrowVault} from "../../src/EscrowVault.sol";
import {TimelockController} from "../../src/TimelockController.sol";
import {TradeManager} from "../../src/TradeManager.sol";
import {StoexRoles} from "../../src/libraries/StoexRoles.sol";
import {StoexTypes} from "../../src/libraries/StoexTypes.sol";

/// @dev Shared UUPS deployment + wiring for STOEX Gold integration tests (PRD v2.0).
abstract contract StoexFixture is Test {
    GovernanceConfig internal gov;
    WhitelistRegistry internal registry;
    GoldNFT internal gold;
    EscrowVault internal escrow;
    TimelockController internal timelock;
    TradeManager internal trade;

    address internal admin;
    address internal ap;
    address internal vp;
    address internal at;
    address internal pap;
    address internal auditor;
    address internal user;
    address internal vaultBk;

    uint256 internal apKey;
    uint256 internal vpKey;
    uint256 internal atKey;
    address internal forwarder;

    function setUp() public virtual {
        admin = address(this);
        address deployer = address(this);
        (ap, apKey) = makeAddrAndKey("ap");
        (vp, vpKey) = makeAddrAndKey("vp");
        (at, atKey) = makeAddrAndKey("at");
        pap = makeAddr("pap");
        auditor = makeAddr("auditor");
        user = makeAddr("user");
        vaultBk = makeAddr("vaultBk");
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

        address goldAddr;
        {
            GoldNFT impl = new GoldNFT();
            goldAddr = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(GoldNFT.initialize, (deployer, regAddr, forwarder)))
            );
        }
        gold = GoldNFT(goldAddr);

        address escrowAddr;
        {
            EscrowVault impl = new EscrowVault();
            escrowAddr = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(EscrowVault.initialize, (deployer, goldAddr)))
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
                        (deployer, govAddr, regAddr, goldAddr, escrowAddr, timelockAddr, forwarder)
                    )
                )
            );
        }
        trade = TradeManager(tradeAddr);

        gov.setInitialAdmin(admin);
        registry.setInitialAdmin(admin);
        gold.setInitialAdmin(admin);
        escrow.setInitialAdmin(admin);
        timelock.setInitialAdmin(admin);
        trade.setInitialAdmin(admin);

        trade.setRoutingAddresses(ap, address(0xdead), vaultBk);
        escrow.setTradeManager(tradeAddr);
        timelock.setTradeManager(tradeAddr);
        gold.grantRole(StoexRoles.TRADE_MANAGER_ROLE, tradeAddr);
        registry.setTradeManager(tradeAddr);

        trade.grantRole(StoexRoles.AP_ROLE, ap);
        trade.grantRole(StoexRoles.VP_ROLE, vp);
        trade.grantRole(StoexRoles.AT_ROLE, at);
        trade.grantRole(StoexRoles.PAP_ROLE, pap);
        trade.grantRole(StoexRoles.AUDITOR_ROLE, auditor);

        gold.grantRole(StoexRoles.AP_ROLE, ap);

        timelock.grantRole(StoexRoles.AP_ROLE, ap);
        timelock.grantRole(StoexRoles.AT_ROLE, at);

        gov.grantRole(StoexRoles.AT_ROLE, at);
        registry.grantRole(StoexRoles.AT_ROLE, at);

        _registerVerifiedUser(user);
        _registerVerifiedUser(vaultBk);

        _mintPoolInventory(10_000_000_000); // 10 kg in µg (chunked at maxAmountPerTx)
    }

    function _mintPoolInventory(uint256 amountUg) internal {
        uint256 maxPerTx = gov.maxAmountPerTx();
        StoexTypes.MintLotMeta memory lot = StoexTypes.MintLotMeta({
            vaultReceiptId: bytes32(uint256(1)),
            batchId: bytes32(uint256(2)),
            purity: 9999,
            depositTimestamp: block.timestamp,
            apId: ap,
            vpId: vp,
            lockUntilTs: 0,
            amountUg: 0
        });
        uint256 remaining = amountUg;
        while (remaining > 0) {
            uint256 chunk = remaining > maxPerTx ? maxPerTx : remaining;
            vm.prank(forwarder);
            uint256 rid = trade.proposeMintFor(ap, chunk, bytes32(uint256(3)), lot);
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
        registry.verifyKYC(u);
    }

    function _registerPendingKycUser(address u) internal {
        registry.adminRegisterUser(keccak256(abi.encodePacked("p", u)), u, "kyc");
    }

    /// @dev Buy completes atomically in `createBuyRequestFor` (microgram amounts). `fiat_value` is test-scaled with amountUg.
    function _executeBuy(address investor, uint256 amountUg) internal returns (uint256 requestId) {
        vm.prank(forwarder);
        requestId = trade.createBuyRequestFor(
            investor, amountUg, _defaultFiat(amountUg), bytes32(uint256(1)), bytes32(uint256(2))
        );
    }

    function _sellRequest(address investor, uint256 amountUg, bytes32 payoutRef) internal returns (uint256 requestId) {
        vm.prank(forwarder);
        return trade.createSellRequestFor(investor, amountUg, payoutRef);
    }

    function _redeemRequest(address investor, uint256 amountUg, bytes32 deliveryRef) internal returns (uint256 requestId) {
        vm.prank(forwarder);
        return trade.createRedeemRequestFor(investor, amountUg, deliveryRef);
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

    function _proposeMint(address ap_, uint256 amountUg, bytes32 vaultReceiptId, StoexTypes.MintLotMeta memory lot)
        internal
        returns (uint256 requestId)
    {
        vm.prank(forwarder);
        return trade.proposeMintFor(ap_, amountUg, vaultReceiptId, lot);
    }

    function _proposeBurn(address ap_, uint256 amountUg, bytes32 referenceId, string memory reason_)
        internal
        returns (uint256 requestId)
    {
        vm.prank(forwarder);
        return trade.proposeBurnFor(ap_, amountUg, referenceId, reason_);
    }

    function _defaultFiat(uint256 amountUg) internal pure returns (uint256) {
        return amountUg * 100;
    }

    function _packSig(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
