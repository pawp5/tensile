// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IFeeCollector} from "../interfaces/IFeeCollector.sol";
import {Roles} from "../access/Roles.sol";

/// @title FeeCollector (C-18)
/// @notice Receives protocol fees. Fee-paying contracts transfer first, then `notify` for accounting events.
///         Revenue splits to warehouses / inspectors are handled off-chain in v1 (withdraw by ADMIN).
contract FeeCollector is IFeeCollector, TensileAccessControlled {
    using SafeERC20 for IERC20;

    event FeeCollected(bytes32 indexed feeType, address indexed token, uint256 amount, uint256 indexed ref, address source);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(ITensileAccess access_) TensileAccessControlled(access_) {}

    function notify(bytes32 feeType, address token, uint256 amount, uint256 ref) external onlyRole(Roles.FEE_NOTIFIER) {
        emit FeeCollected(feeType, token, amount, ref, msg.sender);
    }

    function withdraw(IERC20 token, address to, uint256 amount) external onlyAdmin {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit Withdrawn(address(token), to, amount);
    }
}
