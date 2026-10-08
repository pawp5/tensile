// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFeeCollector (C-18)
interface IFeeCollector {
    function notify(bytes32 feeType, address token, uint256 amount, uint256 ref) external;
}
