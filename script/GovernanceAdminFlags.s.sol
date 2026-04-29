// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {GovernanceConfig} from "../src/GovernanceConfig.sol";

/// @title GovernanceAdminFlags
/// @notice `DEFAULT_ADMIN_ROLE` on `GovernanceConfig` toggles VP requirement for Redeem/Mint/Burn approval paths.
/// @dev Required env: `PRIVATE_KEY` (admin), `GOVERNANCE_CONFIG`, `VP_REQUIRED` (`true` / `false` for `vm.envBool`).
/// @dev Example:
/// `VP_REQUIRED=false forge script script/GovernanceAdminFlags.s.sol:GovernanceAdminFlags --rpc-url amoy --broadcast`
contract GovernanceAdminFlags is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        bool required = vm.envBool("VP_REQUIRED");

        vm.startBroadcast(pk);

        GovernanceConfig gov = GovernanceConfig(vm.envAddress("GOVERNANCE_CONFIG"));
        gov.setVpRequiredForApprovals(required);
        console2.log("vpRequiredForApprovals set to", required);

        vm.stopBroadcast();
    }
}
