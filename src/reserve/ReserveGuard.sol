// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IReserveGuard} from "../interfaces/IReserveGuard.sol";
import {IWarehouseRegistry} from "../interfaces/IWarehouseRegistry.sol";
import {IMaterialPassport} from "../interfaces/IMaterialPassport.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title ReserveGuard (C-10)
/// @notice Circuit-breaker: a warehouse is healthy only if it is NOT frozen, its reserve feed is fresh AND
///         reported reserve >= kilograms of live tokens (C-06.outstandingKg). Anyone can `poke`
///         an unhealthy warehouse to freeze it.
/// @dev Reads the feed ONLY through AggregatorV3Interface (Chainlink PoR compatible).
contract ReserveGuard is IReserveGuard, TensileAccessControlled {
    bytes32 public constant REASON_BREACH = "RESERVE_BREACH";

    IWarehouseRegistry public immutable warehouses;
    IMaterialPassport public immutable passport;
    uint256 public maxStaleness;

    event ReserveBreach(uint32 indexed warehouseId, uint256 reserveKg, uint256 outstandingKg, bool stale);
    event MaxStalenessSet(uint256 maxStaleness);

    error InvalidStaleness();

    constructor(ITensileAccess access_, IWarehouseRegistry warehouses_, IMaterialPassport passport_, uint256 maxStaleness_)
        TensileAccessControlled(access_)
    {
        if (address(warehouses_) == address(0) || address(passport_) == address(0)) revert ZeroAddress();
        if (maxStaleness_ == 0) revert InvalidStaleness();
        warehouses = warehouses_;
        passport = passport_;
        maxStaleness = maxStaleness_;
    }

    function setMaxStaleness(uint256 s) external onlyAdmin {
        if (s == 0) revert InvalidStaleness();
        maxStaleness = s;
        emit MaxStalenessSet(s);
    }

    /// @return reserveKg reported reserve (0 if missing/invalid)
    /// @return fresh whether the report is present, non-negative and within maxStaleness
    function reserveOf(uint32 warehouseId) public view returns (uint256 reserveKg, bool fresh) {
        address feed = warehouses.reserveFeedOf(warehouseId);
        if (feed == address(0)) return (0, false);
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer < 0 || updatedAt == 0 || updatedAt > block.timestamp) return (0, false);
        // Normalise to kilograms if an external feed uses decimals.
        uint8 dec = IAggregatorV3(feed).decimals();
        reserveKg = uint256(answer) / (10 ** dec);
        fresh = block.timestamp - updatedAt <= maxStaleness;
    }

    function isHealthy(uint32 warehouseId) public view returns (bool) {
        return canAdd(warehouseId, 0);
    }

    /// @dev Returns false for frozen warehouses too (e.g. frozen by a redemption dispute with healthy reserves).
    function canAdd(uint32 warehouseId, uint256 addKg) public view returns (bool) {
        if (warehouses.isFrozen(warehouseId)) return false;
        (uint256 reserveKg, bool fresh) = reserveOf(warehouseId);
        if (!fresh) return false;
        return reserveKg >= passport.outstandingKg(warehouseId) + addKg;
    }

    /// @notice Permissionless. Freezes the warehouse in C-03 if it is unhealthy.
    function poke(uint32 warehouseId) external returns (bool healthy) {
        if (warehouses.isFrozen(warehouseId)) return false;
        healthy = isHealthy(warehouseId);
        if (!healthy) {
            (uint256 reserveKg, bool fresh) = reserveOf(warehouseId);
            warehouses.freeze(warehouseId, REASON_BREACH);
            emit ReserveBreach(warehouseId, reserveKg, passport.outstandingKg(warehouseId), !fresh);
        }
    }
}
