// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

/// @title ICreditRouter (C-15)
interface ICreditRouter {
    function borrowerOf(uint256 tokenId) external view returns (address);
    function debtOf(uint256 tokenId) external view returns (uint256);
    function collateralOf(uint256 tokenId) external view returns (uint256);
    function payoffFor(uint256 tokenId, address recipient) external returns (uint256 paid);
}
