// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TensileAccessManager} from "../src/access/TensileAccessManager.sol";
import {Roles} from "../src/access/Roles.sol";

/// @notice Grants every role defined by Roles.sol to ALL_ROLES_ACCOUNT on the selected deployment.
/// @dev This includes DEFAULT_ADMIN_ROLE and contract-to-contract roles. Use only when that full privilege
///      set is intended. The operation sends one grant transaction per missing role and can be rerun safely.
contract GrantAllRoles is Script {
    function run() external {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        require(block.chainid == expectedChainId, "wrong chain id");

        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        TensileAccessManager accessManager =
            TensileAccessManager(vm.parseJsonAddress(json, ".C01_TensileAccessManager"));
        require(address(accessManager).code.length != 0, "access manager has no code");

        address target = vm.envAddress("ALL_ROLES_ACCOUNT");
        require(target != address(0), "target is zero");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(pk);
        require(accessManager.hasRole(Roles.ADMIN, signer), "signer must hold ADMIN");

        vm.startBroadcast(pk);
        _grant(accessManager, Roles.ADMIN, target, "ADMIN");
        _grant(accessManager, Roles.KYC_ADMIN, target, "KYC_ADMIN");
        _grant(accessManager, Roles.INSPECTOR, target, "INSPECTOR");
        _grant(accessManager, Roles.AI_AGENT, target, "AI_AGENT");
        _grant(accessManager, Roles.PRICE_UPDATER, target, "PRICE_UPDATER");
        _grant(accessManager, Roles.RISK_ADMIN, target, "RISK_ADMIN");
        _grant(accessManager, Roles.MINTER, target, "MINTER");
        _grant(accessManager, Roles.REDEEMER, target, "REDEEMER");
        _grant(accessManager, Roles.RECORDER, target, "RECORDER");
        _grant(accessManager, Roles.GUARDIAN, target, "GUARDIAN");
        _grant(accessManager, Roles.REGISTRAR, target, "REGISTRAR");
        _grant(accessManager, Roles.FEE_NOTIFIER, target, "FEE_NOTIFIER");
        _grant(accessManager, Roles.INDEX_RECORDER, target, "INDEX_RECORDER");
        vm.stopBroadcast();

        console.log("All defined roles granted or already held by:", target);
    }

    function _grant(TensileAccessManager accessManager, bytes32 role, address target, string memory name)
        private
    {
        if (!accessManager.hasRole(role, target)) {
            accessManager.grantRole(role, target);
            console.log("Granted role:", name);
        } else {
            console.log("Already held:", name);
        }
    }
}
