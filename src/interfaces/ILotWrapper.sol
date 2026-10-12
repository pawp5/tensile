// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ILotWrapper (C-14)
interface ILotWrapper is IERC20 {
    function tokenId() external view returns (uint256);
    function fullSupply() external view returns (uint256);
    function wrapped() external view returns (bool);
    function wrap(address to) external returns (uint256 minted);
    function unwrap(address to) external;
}
