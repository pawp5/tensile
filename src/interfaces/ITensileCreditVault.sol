// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ITensileCreditVault (C-14b)
/// @notice ERC-4626 USDC vault that aggregates lender liquidity across every per-lot Morpho market.
///         Supplies USDC to a lot's market just-in-time when the router opens a loan, and pulls it back on repay.
///         Only the router may move liquidity; lenders only ever interact with ERC-4626 deposit/withdraw.
interface ITensileCreditVault {
    /// @notice Supply `assets` of the loan token to the Morpho market of `tokenId`, on behalf of the vault.
    /// @dev Router-only. Reverts if cash insufficient or the per-class cap would be exceeded. Also accrues
    ///      interest on every tracked market before updating accounting so new deposits don't dilute.
    function supplyFor(uint256 tokenId, uint256 assets) external returns (uint256 supplied);

    /// @notice Withdraw up to `assets` of the loan token from the Morpho market of `tokenId` into the vault.
    /// @dev Router-only. Idempotent: pass type(uint256).max to withdraw everything currently supplied there.
    function withdrawFor(uint256 tokenId, uint256 assets) external returns (uint256 withdrawn);

    /// @notice Called by the router AFTER repayment USDC has already been pulled into the vault from the payer.
    ///         `interest` is the earned portion to credit to lenders; `principal` returns to idle cash.
    function onRepay(uint256 tokenId, uint256 principal, uint256 interest) external;

    /// @notice Called by the router when a loan close observes bad debt on Morpho for that market.
    ///         Debits `assets` from `totalSuppliedAssets`, immediately dropping the share price.
    function onLoss(uint256 tokenId, uint256 assets) external;

    // asset() comes from ERC-4626
    function router() external view returns (address);
    function suppliedForMarket(uint256 tokenId) external view returns (uint256);
    function suppliedForClass(bytes32 classKey) external view returns (uint256);
    function totalSuppliedAssets() external view returns (uint256);
}
