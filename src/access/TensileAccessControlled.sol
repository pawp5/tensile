// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {Roles} from "./Roles.sol";

/// @title TensileAccessControlled
/// @notice Base for contracts whose permissions live in C-01 TensileAccessManager.
abstract contract TensileAccessControlled {
    ITensileAccess public immutable access;

    error Unauthorized(address caller, bytes32 role);
    error ZeroAddress();

    constructor(ITensileAccess access_) {
        if (address(access_) == address(0)) revert ZeroAddress();
        access = access_;
    }

    modifier onlyRole(bytes32 role) {
        _checkRole(role);
        _;
    }

    modifier onlyAdmin() {
        _checkRole(Roles.ADMIN);
        _;
    }

    function _checkRole(bytes32 role) internal view {
        if (!access.hasRole(role, msg.sender)) revert Unauthorized(msg.sender, role);
    }

    function _hasRole(bytes32 role, address account) internal view returns (bool) {
        return access.hasRole(role, account);
    }
}
