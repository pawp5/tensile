// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {MarketParams} from "morpho-blue/interfaces/IMorpho.sol";

/// @title IMarketRegistry (C-12)
interface IMarketRegistry {
    struct ClassConfig {
        address oracle; // TensileMorphoOracle for (materialCode, warehouseId)
        uint256 lltv; // Morpho liquidation LTV (WAD), must be enabled on Morpho
        uint16 routerMaxLtvBps; // stricter borrow limit enforced by CreditRouter
        uint32 maxAttestationAge; // seconds since last (re)inspection allowed for new borrowing
        bool enabled;
    }

    function classOf(uint256 tokenId) external view returns (ClassConfig memory);
    function ensureLotMarket(uint256 tokenId) external returns (MarketParams memory);
    function marketParamsOf(uint256 tokenId) external view returns (MarketParams memory);
    function wrapperOf(uint256 tokenId) external view returns (address);
    function isWrapper(address account) external view returns (bool);
    function tokenIdOfWrapper(address wrapper) external view returns (uint256);
}
