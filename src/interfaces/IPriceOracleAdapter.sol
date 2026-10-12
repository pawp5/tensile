// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceOracleAdapter (C-11)
interface IPriceOracleAdapter {
    /// @return USD per tonne, 8 decimals, AFTER the regional location haircut. Reverts if missing/stale/invalid.
    function pricePerTonne(bytes32 materialCode, bytes32 regionCode) external view returns (uint256);
    /// @return Value of the whole lot in loan-token units (e.g. USDC, 6 decimals).
    function lotValue(uint256 tokenId) external view returns (uint256);
    /// @notice Reverts if the stablecoin/USD feed (when configured) is below the de-peg floor or stale.
    function requireStablePeg() external view;
    function loanTokenDecimals() external view returns (uint8);
}
