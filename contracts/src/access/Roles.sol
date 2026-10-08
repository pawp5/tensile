// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Roles
/// @notice All role identifiers used across Tensile. Held in C-01 TensileAccessManager.
library Roles {
    /// @dev Same value as OpenZeppelin AccessControl.DEFAULT_ADMIN_ROLE. Must be a multisig on public networks.
    bytes32 internal constant ADMIN = 0x00;

    // ---- human / service roles ----
    bytes32 internal constant KYC_ADMIN = keccak256("TENSILE_KYC_ADMIN");
    bytes32 internal constant INSPECTOR = keccak256("TENSILE_INSPECTOR");
    bytes32 internal constant AI_AGENT = keccak256("TENSILE_AI_AGENT");
    bytes32 internal constant PRICE_UPDATER = keccak256("TENSILE_PRICE_UPDATER");
    bytes32 internal constant RISK_ADMIN = keccak256("TENSILE_RISK_ADMIN");

    // ---- contract-to-contract roles ----
    bytes32 internal constant MINTER = keccak256("TENSILE_MINTER"); // C-07 -> C-06.mint
    bytes32 internal constant REDEEMER = keccak256("TENSILE_REDEEMER"); // C-08 -> C-06 redemption state + burn
    bytes32 internal constant RECORDER = keccak256("TENSILE_RECORDER"); // C-07, C-08 -> C-05.record
    bytes32 internal constant GUARDIAN = keccak256("TENSILE_GUARDIAN"); // C-10, C-08 -> C-03.freeze
    bytes32 internal constant REGISTRAR = keccak256("TENSILE_REGISTRAR"); // C-12 -> C-02.setProtocol (wrappers)
    bytes32 internal constant FEE_NOTIFIER = keccak256("TENSILE_FEE_NOTIFIER"); // C-07, C-15, C-16 -> C-18
    bytes32 internal constant INDEX_RECORDER = keccak256("TENSILE_INDEX_RECORDER"); // C-16 -> C-19
}
