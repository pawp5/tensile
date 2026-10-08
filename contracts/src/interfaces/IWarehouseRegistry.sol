// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IWarehouseRegistry (C-03)
interface IWarehouseRegistry {
    struct Warehouse {
        address operator;
        bytes32 regionCode;
        address reserveFeed;
        bool active;
        bool frozen;
        string metaURI;
    }

    function exists(uint32 warehouseId) external view returns (bool);
    function operatorOf(uint32 warehouseId) external view returns (address);
    function regionOf(uint32 warehouseId) external view returns (bytes32);
    function reserveFeedOf(uint32 warehouseId) external view returns (address);
    function isActive(uint32 warehouseId) external view returns (bool);
    function isFrozen(uint32 warehouseId) external view returns (bool);
    function freeze(uint32 warehouseId, bytes32 reason) external;
}
