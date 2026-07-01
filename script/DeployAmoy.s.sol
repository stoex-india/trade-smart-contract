// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GovernanceConfig} from "../src/GovernanceConfig.sol";
import {WhitelistRegistry} from "../src/WhitelistRegistry.sol";
import {AssetRegistry} from "../src/AssetRegistry.sol";
import {AssetProviderRegistry} from "../src/AssetProviderRegistry.sol";
import {AssetLedger} from "../src/AssetLedger.sol";
import {EscrowVault} from "../src/EscrowVault.sol";
import {TimelockController} from "../src/TimelockController.sol";
import {TradeManager} from "../src/TradeManager.sol";
import {StoexRoles} from "../src/libraries/StoexRoles.sol";
import {StoexIds} from "../src/libraries/StoexIds.sol";

/// @notice UUPS deployment for Polygon Amoy.
/// @dev Phase 1 (deployer key): deploy proxies + `setInitialAdmin`.
///      Phase 2 (admin key): register assets/providers + wire — same tx when `INITIAL_ADMIN == deployer`,
///      or run `ConfigureDeployment.s.sol` with admin `PRIVATE_KEY` when they differ.
contract DeployAmoy is Script {
    struct Deployment {
        address gov;
        address registry;
        address assetReg;
        address providerReg;
        address ledger;
        address escrow;
        address timelock;
        address trade;
    }

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        address initialAdmin = vm.envOr("INITIAL_ADMIN", deployer);
        address trustedForwarder = vm.envAddress("RELAYER_SMART_CONTRACT");
        if (trustedForwarder == address(0)) revert("RELAYER_SMART_CONTRACT is zero");

        vm.startBroadcast(deployerPk);
        Deployment memory d = _deployProxies(deployer, trustedForwarder);
        _setInitialAdmins(d, initialAdmin);
        vm.stopBroadcast();

        if (initialAdmin == deployer) {
            uint256 adminPk = vm.envOr("ADMIN_PRIVATE_KEY", deployerPk);
            vm.startBroadcast(adminPk);
            _configureDeployment(d, initialAdmin, trustedForwarder);
            vm.stopBroadcast();
        } else {
            console2.log("INITIAL_ADMIN != deployer: run ConfigureDeployment.s.sol with admin PRIVATE_KEY");
        }

        _logAddresses(d, trustedForwarder, initialAdmin);
    }

    function _deployProxies(address deployer, address trustedForwarder) private returns (Deployment memory d) {
        {
            GovernanceConfig impl = new GovernanceConfig();
            d.gov = address(new ERC1967Proxy(address(impl), abi.encodeCall(GovernanceConfig.initialize, (deployer))));
        }
        {
            WhitelistRegistry impl = new WhitelistRegistry();
            d.registry = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(WhitelistRegistry.initialize, (deployer, trustedForwarder)))
            );
        }
        {
            AssetRegistry impl = new AssetRegistry();
            d.assetReg = address(new ERC1967Proxy(address(impl), abi.encodeCall(AssetRegistry.initialize, (deployer))));
        }
        {
            AssetProviderRegistry impl = new AssetProviderRegistry();
            d.providerReg = address(
                new ERC1967Proxy(
                    address(impl), abi.encodeCall(AssetProviderRegistry.initialize, (deployer, d.assetReg))
                )
            );
        }
        {
            AssetLedger impl = new AssetLedger();
            d.ledger = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(AssetLedger.initialize, (deployer, d.registry, trustedForwarder)))
            );
        }
        {
            EscrowVault impl = new EscrowVault();
            d.escrow = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(EscrowVault.initialize, (deployer, d.ledger)))
            );
        }
        {
            TimelockController impl = new TimelockController();
            d.timelock = address(
                new ERC1967Proxy(address(impl), abi.encodeCall(TimelockController.initialize, (deployer)))
            );
        }
        {
            TradeManager impl = new TradeManager();
            d.trade = address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        TradeManager.initialize,
                        (deployer, d.gov, d.registry, d.ledger, d.escrow, d.timelock, d.assetReg, d.providerReg, trustedForwarder)
                    )
                )
            );
        }
    }

    function _setInitialAdmins(Deployment memory d, address initialAdmin) private {
        GovernanceConfig(d.gov).setInitialAdmin(initialAdmin);
        WhitelistRegistry(d.registry).setInitialAdmin(initialAdmin);
        AssetRegistry(d.assetReg).setInitialAdmin(initialAdmin);
        AssetProviderRegistry(d.providerReg).setInitialAdmin(initialAdmin);
        AssetLedger(d.ledger).setInitialAdmin(initialAdmin);
        EscrowVault(d.escrow).setInitialAdmin(initialAdmin);
        TimelockController(d.timelock).setInitialAdmin(initialAdmin);
        TradeManager(d.trade).setInitialAdmin(initialAdmin);
    }

    function _configureDeployment(Deployment memory d, address initialAdmin, address) private {
        address apOperator = vm.envOr("ROLE_AP", initialAdmin);
        address apPayout = vm.envOr("ASSET_PROVIDER_PAYOUT", apOperator);
        address rSink = vm.envOr("REDEEM_SINK", address(0x000000000000000000000000000000000000dEaD));
        bytes32 providerId = keccak256(bytes(vm.envOr("DEFAULT_PROVIDER_LABEL", string("AP1"))));

        AssetRegistry(d.assetReg).registerAsset(StoexIds.GOLD, "AU", "Gold", 6);
        AssetRegistry(d.assetReg).registerAsset(StoexIds.SILVER, "AG", "Silver", 6);

        AssetProviderRegistry pr = AssetProviderRegistry(d.providerReg);
        pr.registerProvider(providerId, vm.envOr("DEFAULT_PROVIDER_NAME", string("Default AP")));
        pr.addProviderOperator(providerId, apOperator);
        pr.setProviderAsset(providerId, StoexIds.GOLD, true);
        pr.setProviderAsset(providerId, StoexIds.SILVER, true);
        pr.setAssetRouting(providerId, StoexIds.GOLD, apPayout, rSink);
        pr.setAssetRouting(providerId, StoexIds.SILVER, apPayout, rSink);

        EscrowVault(d.escrow).setTradeManager(d.trade);
        TimelockController(d.timelock).setTradeManager(d.trade);
        AssetLedger(d.ledger).grantRole(StoexRoles.TRADE_MANAGER_ROLE, d.trade);
        WhitelistRegistry(d.registry).setTradeManager(d.trade);
    }

    function _logAddresses(Deployment memory d, address trustedForwarder, address initialAdmin) private view {
        console2.log("GovernanceConfig", d.gov);
        console2.log("AssetRegistry", d.assetReg);
        console2.log("AssetProviderRegistry", d.providerReg);
        console2.log("WhitelistRegistry", d.registry);
        console2.log("AssetLedger", d.ledger);
        console2.log("EscrowVault", d.escrow);
        console2.log("TimelockController", d.timelock);
        console2.log("TradeManager", d.trade);
        console2.log("Trusted forwarder", trustedForwarder);
        console2.log("INITIAL_ADMIN", initialAdmin);
    }
}
