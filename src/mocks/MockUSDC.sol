// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC (C-24) — TESTNET ONLY
/// @notice 6-decimal stablecoin with a capped public faucet. Never deploy on mainnet.
contract MockUSDC is ERC20 {
    uint256 public constant FAUCET_CAP = 1_000_000e6;

    error FaucetCapExceeded();

    constructor() ERC20("Mock USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function faucet(address to, uint256 amount) external {
        if (amount > FAUCET_CAP) revert FaucetCapExceeded();
        _mint(to, amount);
    }
}
