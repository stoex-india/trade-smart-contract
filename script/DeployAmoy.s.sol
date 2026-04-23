// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

import {GovernanceConfig} from "../src/GovernanceConfig.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {GoldNFT} from "../src/GoldNFT.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";

/// @notice UUPS deployment for Polygon Amoy. Example:
/// `forge script script/DeployAmoy.s.sol:DeployAmoy --rpc-url amoy --broadcast`
contract DeployAmoy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address admin = vm.addr(pk);
        address apPayout = vm.envOr("ASSET_PROVIDER_PAYOUT", admin);
        address rSink = vm.envOr("REDEEM_SINK", address(0x000000000000000000000000000000000000dEaD));
        address vaultBk = vm.envOr("VAULT_BOOKKEEPING", admin);
        string memory forwarderName = vm.envOr("FORWARDER_NAME", string("STOEX Forwarder"));

        vm.startBroadcast(pk);
        address forwarder = address(new ERC2771Forwarder(forwarderName));

        address gov;
        {
            GovernanceConfig impl = new GovernanceConfig();
            gov = address(new ERC1967Proxy(address(impl), abi.encodeCall(GovernanceConfig.initialize, (admin))));
        }

        address registry;
        {
            WhitelistRegistry impl = new WhitelistRegistry();
            registry = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(WhitelistRegistry.initialize, (admin, forwarder)))
            );
        }

        address gold;
        {
            GoldNFT impl = new GoldNFT();
            gold = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(GoldNFT.initialize, (admin, registry, forwarder)))
            );
        }

        address escrow;
        {
            EscrowVault impl = new EscrowVault();
            escrow = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(EscrowVault.initialize, (admin, gold)))
            );
        }

        address timelock;
        {
            TimelockController impl = new TimelockController();
            timelock = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(TimelockController.initialize, (admin)))
            );
        }

        address trade;
        {
            TradeManager impl = new TradeManager();
            trade = address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(TradeManager.initialize, (admin, gov, registry, gold, escrow, timelock, forwarder))
                )
            );
        }

        TradeManager(trade).setRoutingAddresses(apPayout, rSink, vaultBk);

        EscrowVault(escrow).setTradeManager(trade);
        TimelockController(timelock).setTradeManager(trade);
        GoldNFT(gold).grantRole(StoexRoles.TRADE_MANAGER_ROLE, trade);

        vm.stopBroadcast();

        console2.log("GovernanceConfig", gov);
        console2.log("ERC2771Forwarder", forwarder);
        console2.log("WhitelistRegistry", registry);
        console2.log("GoldNFT", gold);
        console2.log("EscrowVault", escrow);
        console2.log("TimelockController", timelock);
        console2.log("TradeManager", trade);
    }
}
