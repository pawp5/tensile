// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {ILotWrapper} from "../interfaces/ILotWrapper.sol";
import {IMaterialPassport} from "../interfaces/IMaterialPassport.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";

/// @title LotWrapper (C-14)
/// @notice ERC-20 wrapper for exactly ONE lot (deployed per lot by C-12). Needed because Morpho Blue only
///         accepts ERC-20 collateral. 1e18 units = 1 kg; total supply while wrapped = quantityKg * 1e18.
///         - wrap:   pull the lot NFT from msg.sender (must have approved this wrapper), mint full supply.
///         - unwrap: burn the FULL supply from msg.sender, send the NFT to `to`.
///         Transfers / mints only to KYC-verified accounts or protocol contracts (Morpho, CreditRouter).
///         Tokens may only be deposited INTO Morpho by the CreditRouter, so nobody (e.g. a liquidator holding
///         seized tokens) can borrow against the lot directly on Morpho and bypass Tensile's risk checks.
contract LotWrapper is ILotWrapper, ERC20, TensileAccessControlled {
    IMaterialPassport public immutable passport;
    IIdentityRegistry public immutable identity;
    uint256 public immutable tokenId;
    uint256 public immutable fullSupply;
    address public immutable morpho;
    address public immutable router;

    bool public wrapped;

    event Wrapped(address indexed from, address indexed to, uint256 amount);
    event Unwrapped(address indexed by, address indexed to);
    event Recovered(address indexed to);

    error AlreadyWrapped();
    error NotWrapped();
    error RecipientNotVerified(address to);
    error NothingToRecover();
    error CollateralOnlyViaRouter();

    constructor(
        ITensileAccess access_,
        IMaterialPassport passport_,
        IIdentityRegistry identity_,
        uint256 tokenId_,
        address morpho_,
        address router_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) TensileAccessControlled(access_) {
        if (
            address(passport_) == address(0) || address(identity_) == address(0) || morpho_ == address(0)
                || router_ == address(0)
        ) revert ZeroAddress();
        morpho = morpho_;
        router = router_;
        passport = passport_;
        identity = identity_;
        tokenId = tokenId_;
        fullSupply = uint256(passport_.lotOf(tokenId_).quantityKg) * 1e18;
    }

    function wrap(address to) external returns (uint256 minted) {
        if (wrapped) revert AlreadyWrapped();
        wrapped = true;
        passport.transferFrom(msg.sender, address(this), tokenId); // reverts unless msg.sender owns & approved
        minted = fullSupply;
        _mint(to, minted);
        emit Wrapped(msg.sender, to, minted);
    }

    function unwrap(address to) external {
        if (!wrapped) revert NotWrapped();
        _burn(msg.sender, fullSupply); // reverts unless caller holds the entire supply
        wrapped = false;
        passport.transferFrom(address(this), to, tokenId);
        emit Unwrapped(msg.sender, to);
    }

    /// @notice Rescue a lot NFT that was sent here with a plain transfer (not via wrap) and is therefore unbacked.
    function recover(address to) external onlyAdmin {
        if (wrapped || passport.ownerOf(tokenId) != address(this)) revert NothingToRecover();
        passport.transferFrom(address(this), to, tokenId);
        emit Recovered(to);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (to == morpho && from != router) revert CollateralOnlyViaRouter();
        if (to != address(0) && !identity.isVerified(to)) revert RecipientNotVerified(to);
        super._update(from, to, value);
    }
}
