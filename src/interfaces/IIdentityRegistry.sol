// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IIdentityRegistry (C-02)
interface IIdentityRegistry {
    /// @return true if `account` is a KYC-verified, non-expired participant OR a whitelisted protocol contract.
    function isVerified(address account) external view returns (bool);
    function setProtocol(address account, bool allowed) external;
}
