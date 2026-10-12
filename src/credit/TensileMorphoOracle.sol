// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IOracle} from "morpho-blue/interfaces/IOracle.sol";
import {IPriceOracleAdapter} from "../interfaces/IPriceOracleAdapter.sol";
import {IWarehouseRegistry} from "../interfaces/IWarehouseRegistry.sol";

/// @title TensileMorphoOracle (C-13)
/// @notice Morpho Blue IOracle for one lot class (materialCode, warehouseId).
///         Morpho expects: price of 1 smallest unit of collateral, quoted in smallest units of the loan token,
///         scaled by 1e36. Collateral = LotWrapper (18 decimals, 1e18 units = 1 kg).
///
///         p8 = USD per tonne (8 dp, after haircut)       -> USD per kg  = p8 / 1e8 / 1e3
///         per wrapper unit (1e-18 kg) in loan units     = p8 * 10^loanDec / (1e8 * 1e3 * 1e18)
///         scaled by 1e36                                = p8 * 10^(loanDec + 7)
/// @dev Reverts (via the adapter) if the price is missing or stale. Consequence: Morpho borrows AND
///      liquidations pause while the price is stale — see SECURITY_REVIEW.md (S-07).
///      The stablecoin is assumed to trade at 1 USD inside this oracle; the de-peg guard lives in C-15.
contract TensileMorphoOracle is IOracle {
    IPriceOracleAdapter public immutable adapter;
    IWarehouseRegistry public immutable warehouses;
    bytes32 public immutable materialCode;
    uint32 public immutable warehouseId;
    uint256 public immutable scale;

    error ZeroAddress();
    error ZeroPrice();

    constructor(IPriceOracleAdapter adapter_, IWarehouseRegistry warehouses_, bytes32 materialCode_, uint32 warehouseId_) {
        if (address(adapter_) == address(0) || address(warehouses_) == address(0)) revert ZeroAddress();
        adapter = adapter_;
        warehouses = warehouses_;
        materialCode = materialCode_;
        warehouseId = warehouseId_;
        scale = 10 ** (uint256(adapter_.loanTokenDecimals()) + 7);
    }

    function price() external view returns (uint256 p) {
        p = adapter.pricePerTonne(materialCode, warehouses.regionOf(warehouseId)) * scale;
        if (p == 0) revert ZeroPrice(); // a zero price would let liquidators seize collateral for free
    }
}
