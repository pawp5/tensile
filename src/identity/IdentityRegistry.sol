// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {Roles} from "../access/Roles.sol";

/// @title IdentityRegistry (C-02)
/// @notice KYC allow-list. Gates who can hold lots (C-06), lot wrapper tokens (C-14) and trade (C-16).
///         Protocol contracts (router, Morpho, wrappers) are whitelisted so they can hold assets in custody.
contract IdentityRegistry is IIdentityRegistry, TensileAccessControlled {
    struct Identity {
        bool verified;
        bytes2 country; // ISO 3166-1 alpha-2
        uint8 tier; // 1 = retail, 2 = business, 3 = institution
        uint64 expiry;
    }

    mapping(address => Identity) private _identities;
    mapping(address => bool) public isProtocol;

    event IdentitySet(address indexed account, bytes2 country, uint8 tier, uint64 expiry);
    event IdentityRevoked(address indexed account);
    event ProtocolSet(address indexed account, bool allowed);

    error InvalidIdentity();

    constructor(ITensileAccess access_) TensileAccessControlled(access_) {}

    function setIdentity(address account, bytes2 country, uint8 tier, uint64 expiry)
        external
        onlyRole(Roles.KYC_ADMIN)
    {
        if (account == address(0)) revert ZeroAddress();
        if (tier == 0 || expiry <= block.timestamp) revert InvalidIdentity();
        _identities[account] = Identity({verified: true, country: country, tier: tier, expiry: expiry});
        emit IdentitySet(account, country, tier, expiry);
    }

    function revoke(address account) external onlyRole(Roles.KYC_ADMIN) {
        delete _identities[account];
        emit IdentityRevoked(account);
    }

    /// @notice Whitelist a protocol contract (CreditRouter, Morpho, LotWrappers...). Callable by ADMIN or REGISTRAR (C-12).
    function setProtocol(address account, bool allowed) external {
        if (!_hasRole(Roles.ADMIN, msg.sender) && !_hasRole(Roles.REGISTRAR, msg.sender)) {
            revert Unauthorized(msg.sender, Roles.REGISTRAR);
        }
        if (account == address(0)) revert ZeroAddress();
        isProtocol[account] = allowed;
        emit ProtocolSet(account, allowed);
    }

    function isVerified(address account) external view returns (bool) {
        if (isProtocol[account]) return true;
        Identity memory id = _identities[account];
        return id.verified && id.expiry > block.timestamp;
    }

    function identityOf(address account) external view returns (Identity memory) {
        return _identities[account];
    }
}
