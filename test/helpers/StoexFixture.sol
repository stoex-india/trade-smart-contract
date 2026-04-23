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
            govAddr = address(new ERC1967Proxy(address(impl), abi.encodeCall(GovernanceConfig.initialize, (admin))));
        }
        gov = GovernanceConfig(govAddr);

        address regAddr;
        {
            WhitelistRegistry impl = new WhitelistRegistry();
            regAddr = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(WhitelistRegistry.initialize, (admin, forwarder)))
            );
        }
        registry = WhitelistRegistry(regAddr);

        address goldAddr;
        {
            GoldNFT impl = new GoldNFT();
            goldAddr = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(GoldNFT.initialize, (admin, regAddr, forwarder)))
            );
        }
        gold = GoldNFT(goldAddr);

        address escrowAddr;
        {
            EscrowVault impl = new EscrowVault();
            escrowAddr = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(EscrowVault.initialize, (admin, goldAddr)))
            );
        }
        escrow = EscrowVault(escrowAddr);

        address timelockAddr;
        {
            TimelockController impl = new TimelockController();
            timelockAddr = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(TimelockController.initialize, (admin)))
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
                        (admin, govAddr, regAddr, goldAddr, escrowAddr, timelockAddr, forwarder)
                    )
                )
            );
        }
        trade = TradeManager(tradeAddr);

        trade.setRoutingAddresses(ap, address(0xdead), vaultBk);
        escrow.setTradeManager(tradeAddr);
        timelock.setTradeManager(tradeAddr);
        gold.grantRole(StoexRoles.TRADE_MANAGER_ROLE, tradeAddr);

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
    }

    function _registerVerifiedUser(address u) internal {
        registry.registerUser(keccak256(abi.encodePacked("u", u)), u, "kyc");
        registry.verifyKYC(u);
        registry.grantRole(StoexRoles.USER_ROLE, u);
        trade.grantRole(StoexRoles.USER_ROLE, u);
    }

    /// @dev Full buy pipeline: AP + AT approve then admin executes.
    function _executeBuy(address investor, uint256 grams) internal returns (uint256 requestId) {
        vm.prank(investor);
        requestId = trade.createBuyRequest(grams, bytes32(uint256(1)));
        vm.prank(ap);
        trade.approveRequest(requestId);
        vm.prank(at);
        trade.approveRequest(requestId);
        trade.executeRequest(requestId);
    }

    function _packSig(uint256 pk, bytes32 digest) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }
}
