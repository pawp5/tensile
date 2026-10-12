// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IReserveGuard (C-10)
interface IReserveGuard {
    function isHealthy(uint32 warehouseId) external view returns (bool);
    function canAdd(uint32 warehouseId, uint256 addKg) external view returns (bool);
    function poke(uint32 warehouseId) external returns (bool healthy);
}
