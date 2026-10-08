// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IPriceIndex} from "../interfaces/IPriceIndex.sol";
import {Roles} from "../access/Roles.sol";

/// @title PriceIndex (C-19)
/// @notice Turns settled marketplace trades into a transaction-based benchmark per (material, region):
///         last price and cumulative volume-weighted average price (VWAP). Start of the "Index" data moat.
contract PriceIndex is IPriceIndex, TensileAccessControlled {
    struct Stats {
        uint256 lastPrice; // USD/t, 8 dp
        uint256 lastQuantityKg;
        uint64 lastAt;
        uint64 trades;
        uint256 cumQuantityKg;
        uint256 cumNotional; // sum(price * qtyKg)
    }

    mapping(bytes32 => mapping(bytes32 => Stats)) private _stats;
    uint256 public minQuantityKg = 1_000; // ignore trades below 1 t (anti-manipulation)

    event TradeRecorded(bytes32 indexed materialCode, bytes32 indexed regionCode, uint256 pricePerTonne, uint256 quantityKg);
    event TradeIgnored(bytes32 indexed materialCode, bytes32 indexed regionCode, uint256 quantityKg);
    event MinQuantitySet(uint256 minQuantityKg);

    constructor(ITensileAccess access_) TensileAccessControlled(access_) {}

    function setMinQuantityKg(uint256 q) external onlyAdmin {
        minQuantityKg = q;
        emit MinQuantitySet(q);
    }

    function record(bytes32 materialCode, bytes32 regionCode, uint256 pricePerTonne, uint256 quantityKg)
        external
        onlyRole(Roles.INDEX_RECORDER)
    {
        if (quantityKg < minQuantityKg || pricePerTonne == 0) {
            emit TradeIgnored(materialCode, regionCode, quantityKg);
            return;
        }
        Stats storage s = _stats[materialCode][regionCode];
        s.lastPrice = pricePerTonne;
        s.lastQuantityKg = quantityKg;
        s.lastAt = uint64(block.timestamp);
        s.trades += 1;
        s.cumQuantityKg += quantityKg;
        s.cumNotional += pricePerTonne * quantityKg;
        emit TradeRecorded(materialCode, regionCode, pricePerTonne, quantityKg);
    }

    function statsOf(bytes32 materialCode, bytes32 regionCode) external view returns (Stats memory) {
        return _stats[materialCode][regionCode];
    }

    function vwap(bytes32 materialCode, bytes32 regionCode) external view returns (uint256) {
        Stats memory s = _stats[materialCode][regionCode];
        return s.cumQuantityKg == 0 ? 0 : s.cumNotional / s.cumQuantityKg;
    }
}
