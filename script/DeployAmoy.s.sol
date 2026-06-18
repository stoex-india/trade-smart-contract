// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GovernanceConfig} from "../src/GovernanceConfig.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {GoldNFT} from "../src/GoldNFT.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";

/// @notice UUPS deployment for Polygon Amoy. Example:
/// `forge script script/DeployAmoy.s.sol:DeployAmoy --rpc-url amoy --broadcast`
/// @dev `PRIVATE_KEY` = **deployer** (temporary; no admin rights until `setInitialAdmin`). `INITIAL_ADMIN` = operations admin (defaults to deployer).
/// If `INITIAL_ADMIN` != deployer, this script only wires routing when you re-run with deployer equal to `INITIAL_ADMIN`, or use `WireProxiesAdmin.s.sol` with the admin key.
contract DeployAmoy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address initialAdmin = vm.envOr("INITIAL_ADMIN", deployer);
        address apPayout = vm.envOr("ASSET_PROVIDER_PAYOUT", initialAdmin);
        address rSink = vm.envOr("REDEEM_SINK", address(0x000000000000000000000000000000000000dEaD));
        address vaultBk = vm.envOr("VAULT_BOOKKEEPING", initialAdmin);
        // Tresori Relayer = ERC-2771 trusted forwarder (must be msg.sender on gasless inner calls).
        address trustedForwarder = vm.envAddress("RELAYER_SMART_CONTRACT");
        if (trustedForwarder == address(0)) revert("RELAYER_SMART_CONTRACT is zero");

        vm.startBroadcast(pk);

        address gov;
        {
            GovernanceConfig impl = new GovernanceConfig();
            gov = address(new ERC1967Proxy(address(impl), abi.encodeCall(GovernanceConfig.initialize, (deployer))));
        }

        address registry;
        {
            WhitelistRegistry impl = new WhitelistRegistry();
            registry = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(WhitelistRegistry.initialize, (deployer, trustedForwarder)))
            );
        }

        address gold;
        {
            GoldNFT impl = new GoldNFT();
            gold = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(GoldNFT.initialize, (deployer, registry, trustedForwarder)))
            );
        }

        address escrow;
        {
            EscrowVault impl = new EscrowVault();
            escrow = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(EscrowVault.initialize, (deployer, gold)))
            );
        }

        address timelock;
        {
            TimelockController impl = new TimelockController();
            timelock = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(TimelockController.initialize, (deployer)))
            );
        }

        address trade;
        {
            TradeManager impl = new TradeManager();
            trade = address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        TradeManager.initialize, (deployer, gov, registry, gold, escrow, timelock, trustedForwarder)
                    )
                )
            );
        }

        GovernanceConfig(gov).setInitialAdmin(initialAdmin);
        WhitelistRegistry(registry).setInitialAdmin(initialAdmin);
        GoldNFT(gold).setInitialAdmin(initialAdmin);
        EscrowVault(escrow).setInitialAdmin(initialAdmin);
        TimelockController(timelock).setInitialAdmin(initialAdmin);
        TradeManager(trade).setInitialAdmin(initialAdmin);

        if (initialAdmin == deployer) {
            TradeManager(trade).setRoutingAddresses(apPayout, rSink, vaultBk);
            EscrowVault(escrow).setTradeManager(trade);
            TimelockController(timelock).setTradeManager(trade);
            GoldNFT(gold).grantRole(StoexRoles.TRADE_MANAGER_ROLE, trade);
            WhitelistRegistry(registry).setTradeManager(trade);
        } else {
            console2.log("INITIAL_ADMIN != deployer: run WireProxiesAdmin.s.sol with admin PRIVATE_KEY");
        }

        vm.stopBroadcast();

        console2.log("GovernanceConfig", gov);
        console2.log("Trusted forwarder", trustedForwarder);
        console2.log("WhitelistRegistry", registry);
        console2.log("GoldNFT", gold);
        console2.log("EscrowVault", escrow);
        console2.log("TimelockController", timelock);
        console2.log("TradeManager", trade);
        console2.log("INITIAL_ADMIN", initialAdmin);
    }
}
