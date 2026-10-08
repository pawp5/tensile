// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITensileAccess (C-01)
/// @notice Minimal view used by every Tensile contract to check roles in the central AccessManager.
interface ITensileAccess {
    function hasRole(bytes32 role, address account) external view returns (bool);
}
