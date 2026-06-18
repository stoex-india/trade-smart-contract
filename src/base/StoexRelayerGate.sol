// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Tresori relayer does not append ERC-2771 suffix bytes. Gasless integrations must call `*For`
/// functions with an explicit actor/wallet; only `msg.sender == trustedForwarder()` may invoke them.
abstract contract StoexRelayerGate {
    function trustedForwarder() public view virtual returns (address);

    modifier onlyTrustedForwarder() {
        if (msg.sender != trustedForwarder()) revert NotTrustedForwarder();
        _;
    }

    error NotTrustedForwarder();
}
