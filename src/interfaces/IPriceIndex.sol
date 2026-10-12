// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceIndex (C-19)
interface IPriceIndex {
    function record(bytes32 materialCode, bytes32 regionCode, uint256 pricePerTonne, uint256 quantityKg) external;
}
