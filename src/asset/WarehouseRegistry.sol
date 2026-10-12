// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IWarehouseRegistry} from "../interfaces/IWarehouseRegistry.sol";
import {Roles} from "../access/Roles.sol";

/// @title WarehouseRegistry (C-03)
/// @notice Approved custodians. Anchors each warehouse's operator key, pricing region, reserve feed and frozen flag.
/// @dev A frozen warehouse blocks: new mints (C-07), transfers of its lots (C-06), wrapping/unwrapping (C-14),
///      new loans (C-15) and marketplace settlement (C-16). Releases against a redemption are still allowed.
contract WarehouseRegistry is IWarehouseRegistry, TensileAccessControlled {
    uint32 public warehouseCount;
    mapping(uint32 => Warehouse) private _warehouses;

    event WarehouseRegistered(uint32 indexed id, address indexed operator, bytes32 regionCode, string metaURI);
    event OperatorSet(uint32 indexed id, address indexed operator);
    event ReserveFeedSet(uint32 indexed id, address indexed feed);
    event ActiveSet(uint32 indexed id, bool active);
    event MetaURISet(uint32 indexed id, string metaURI);
    event WarehouseFrozen(uint32 indexed id, bytes32 reason, address indexed by);
    event WarehouseUnfrozen(uint32 indexed id);

    error UnknownWarehouse(uint32 id);
    error InvalidRegion();

    constructor(ITensileAccess access_) TensileAccessControlled(access_) {}

    modifier known(uint32 id) {
        if (id == 0 || id > warehouseCount) revert UnknownWarehouse(id);
        _;
    }

    // ------------------------------------------------------------------ admin

    function registerWarehouse(address operator, bytes32 regionCode, string calldata metaURI)
        external
        onlyAdmin
        returns (uint32 id)
    {
        if (operator == address(0)) revert ZeroAddress();
        if (regionCode == bytes32(0)) revert InvalidRegion();
        id = ++warehouseCount;
        Warehouse storage w = _warehouses[id];
        w.operator = operator;
        w.regionCode = regionCode;
        w.active = true;
        w.metaURI = metaURI;
        emit WarehouseRegistered(id, operator, regionCode, metaURI);
    }

    function setOperator(uint32 id, address operator) external onlyAdmin known(id) {
        if (operator == address(0)) revert ZeroAddress();
        _warehouses[id].operator = operator;
        emit OperatorSet(id, operator);
    }

    /// @notice Point a warehouse at its reserve feed (C-09 today, an official Chainlink PoR feed later).
    function setReserveFeed(uint32 id, address feed) external onlyAdmin known(id) {
        _warehouses[id].reserveFeed = feed;
        emit ReserveFeedSet(id, feed);
    }

    function setActive(uint32 id, bool active) external onlyAdmin known(id) {
        _warehouses[id].active = active;
        emit ActiveSet(id, active);
    }

    function setMetaURI(uint32 id, string calldata metaURI) external onlyAdmin known(id) {
        _warehouses[id].metaURI = metaURI;
        emit MetaURISet(id, metaURI);
    }

    /// @notice Circuit-breaker. Callable by GUARDIAN contracts (C-10 ReserveGuard, C-08 disputes) or ADMIN.
    function freeze(uint32 id, bytes32 reason) external known(id) {
        if (!_hasRole(Roles.GUARDIAN, msg.sender) && !_hasRole(Roles.ADMIN, msg.sender)) {
            revert Unauthorized(msg.sender, Roles.GUARDIAN);
        }
        if (_warehouses[id].frozen) return;
        _warehouses[id].frozen = true;
        emit WarehouseFrozen(id, reason, msg.sender);
    }

    /// @notice Unfreezing is always a human decision taken after reconciliation.
    function unfreeze(uint32 id) external onlyAdmin known(id) {
        _warehouses[id].frozen = false;
        emit WarehouseUnfrozen(id);
    }

    // ------------------------------------------------------------------ views

    function exists(uint32 id) public view returns (bool) {
        return id != 0 && id <= warehouseCount;
    }

    function getWarehouse(uint32 id) external view known(id) returns (Warehouse memory) {
        return _warehouses[id];
    }

    function operatorOf(uint32 id) external view known(id) returns (address) {
        return _warehouses[id].operator;
    }

    function regionOf(uint32 id) external view known(id) returns (bytes32) {
        return _warehouses[id].regionCode;
    }

    function reserveFeedOf(uint32 id) external view known(id) returns (address) {
        return _warehouses[id].reserveFeed;
    }

    function isActive(uint32 id) external view returns (bool) {
        return exists(id) && _warehouses[id].active;
    }

    function isFrozen(uint32 id) external view known(id) returns (bool) {
        return _warehouses[id].frozen;
    }
}
