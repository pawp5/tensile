// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title TensileAccessManager (C-01)
/// @notice Single role registry for the whole protocol. Every other contract checks roles here,
///         so roles are granted/revoked in one place.
/// @dev DEFAULT_ADMIN_ROLE (0x00) administers every role. Hand it to a Safe multisig after deployment.
contract TensileAccessManager is AccessControl {
    error ZeroAddress();

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }
}
