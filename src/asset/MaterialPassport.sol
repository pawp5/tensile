// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IMaterialPassport} from "../interfaces/IMaterialPassport.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {IWarehouseRegistry} from "../interfaces/IWarehouseRegistry.sol";
import {Roles} from "../access/Roles.sol";

/// @title MaterialPassport (C-06)
/// @notice ERC-721 digital twin of a warehouse receipt. One token = one lot of one material in one warehouse.
/// @dev Fraud model hinges on `_update`:
///      - a lot only moves while FREE (not REDEEMING),
///      - never while its warehouse is frozen,
///      - only to KYC-verified accounts or whitelisted protocol contracts.
///      Collateralisation does NOT need a LOCKED state: the lot is moved into its LotWrapper (C-14), so the
///      seller physically no longer holds it and can neither sell nor re-pledge it.
contract MaterialPassport is IMaterialPassport, ERC721, TensileAccessControlled {
    IIdentityRegistry public immutable identity;
    IWarehouseRegistry public immutable warehouses;

    address public attestationRegistry;
    string private _baseTokenURI;
    uint256 public nextTokenId = 1;

    mapping(uint256 => Lot) private _lots;
    mapping(uint32 => uint256) public outstandingKg;
    mapping(bytes32 => bool) public certUsed;

    event LotMinted(
        uint256 indexed tokenId,
        address indexed owner,
        bytes32 indexed materialCode,
        uint32 warehouseId,
        uint96 quantityKg,
        bytes32 certHash,
        string evidenceURI
    );
    event LotStateChanged(uint256 indexed tokenId, LotState from, LotState to);
    event LotBurned(uint256 indexed tokenId, uint32 indexed warehouseId, uint96 quantityKg);
    event LotAttested(uint256 indexed tokenId, uint64 timestamp);
    event AttestationRegistrySet(address registry);
    event BaseURISet(string baseURI);

    error CertificateAlreadyUsed(bytes32 certHash);
    error InvalidLot();
    error UnknownWarehouse(uint32 warehouseId);
    error LotNotTransferable(uint256 tokenId, LotState state);
    error WarehouseIsFrozen(uint32 warehouseId);
    error RecipientNotVerified(address to);
    error BadState(uint256 tokenId, LotState state);
    error NotAttestationRegistry();

    constructor(
        ITensileAccess access_,
        IIdentityRegistry identity_,
        IWarehouseRegistry warehouses_,
        string memory baseURI_
    ) ERC721("Tensile Material Passport", "TMP") TensileAccessControlled(access_) {
        if (address(identity_) == address(0) || address(warehouses_) == address(0)) revert ZeroAddress();
        identity = identity_;
        warehouses = warehouses_;
        _baseTokenURI = baseURI_;
    }

    // ------------------------------------------------------------------ admin

    function setAttestationRegistry(address registry) external onlyAdmin {
        if (registry == address(0)) revert ZeroAddress();
        attestationRegistry = registry;
        emit AttestationRegistrySet(registry);
    }

    function setBaseURI(string calldata baseURI_) external onlyAdmin {
        _baseTokenURI = baseURI_;
        emit BaseURISet(baseURI_);
    }

    // ------------------------------------------------------------------ minting (C-07 only)

    function mint(
        address to,
        bytes32 materialCode,
        uint32 warehouseId,
        uint96 quantityKg,
        bytes32 certHash,
        string calldata evidenceURI
    ) external onlyRole(Roles.MINTER) returns (uint256 tokenId) {
        if (quantityKg == 0 || certHash == bytes32(0) || materialCode == bytes32(0)) revert InvalidLot();
        if (!warehouses.exists(warehouseId)) revert UnknownWarehouse(warehouseId);
        if (certUsed[certHash]) revert CertificateAlreadyUsed(certHash);
        if (!identity.isVerified(to)) revert RecipientNotVerified(to);

        certUsed[certHash] = true;
        tokenId = nextTokenId++;

        _lots[tokenId] = Lot({
            materialCode: materialCode,
            regionCode: warehouses.regionOf(warehouseId),
            warehouseId: warehouseId,
            quantityKg: quantityKg,
            mintedAt: uint64(block.timestamp),
            lastAttestedAt: uint64(block.timestamp),
            state: LotState.FREE,
            certHash: certHash,
            evidenceURI: evidenceURI
        });
        outstandingKg[warehouseId] += quantityKg;

        _mint(to, tokenId);
        emit LotMinted(tokenId, to, materialCode, warehouseId, quantityKg, certHash, evidenceURI);
    }

    // ------------------------------------------------------------------ redemption (C-08 only)

    function setRedeeming(uint256 tokenId) external onlyRole(Roles.REDEEMER) {
        _transition(tokenId, LotState.FREE, LotState.REDEEMING);
    }

    function clearRedeeming(uint256 tokenId) external onlyRole(Roles.REDEEMER) {
        _transition(tokenId, LotState.REDEEMING, LotState.FREE);
    }

    /// @notice Burns a lot that is being redeemed. Lot data is kept for history (state becomes NONE).
    function burn(uint256 tokenId) external onlyRole(Roles.REDEEMER) {
        Lot storage l = _lots[tokenId];
        if (l.state != LotState.REDEEMING) revert BadState(tokenId, l.state);
        outstandingKg[l.warehouseId] -= l.quantityKg;
        l.state = LotState.NONE;
        _burn(tokenId);
        emit LotStateChanged(tokenId, LotState.REDEEMING, LotState.NONE);
        emit LotBurned(tokenId, l.warehouseId, l.quantityKg);
    }

    // ------------------------------------------------------------------ attestations (C-05 only)

    function recordAttestation(uint256 tokenId) external {
        if (msg.sender != attestationRegistry) revert NotAttestationRegistry();
        if (_ownerOf(tokenId) == address(0)) revert BadState(tokenId, _lots[tokenId].state);
        _lots[tokenId].lastAttestedAt = uint64(block.timestamp);
        emit LotAttested(tokenId, uint64(block.timestamp));
    }

    // ------------------------------------------------------------------ transfer gating

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) {
            Lot storage l = _lots[tokenId];
            if (l.state != LotState.FREE) revert LotNotTransferable(tokenId, l.state);
            if (warehouses.isFrozen(l.warehouseId)) revert WarehouseIsFrozen(l.warehouseId);
            if (!identity.isVerified(to)) revert RecipientNotVerified(to);
        }
        return super._update(to, tokenId, auth);
    }

    // ------------------------------------------------------------------ views

    function lotOf(uint256 tokenId) external view returns (Lot memory) {
        return _lots[tokenId];
    }

    function stateOf(uint256 tokenId) external view returns (LotState) {
        return _lots[tokenId].state;
    }

    function exists(uint256 tokenId) external view returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function _transition(uint256 tokenId, LotState from, LotState to) internal {
        Lot storage l = _lots[tokenId];
        if (_ownerOf(tokenId) == address(0) || l.state != from) revert BadState(tokenId, l.state);
        l.state = to;
        emit LotStateChanged(tokenId, from, to);
    }
}
