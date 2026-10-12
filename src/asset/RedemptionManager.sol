// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IMaterialPassport} from "../interfaces/IMaterialPassport.sol";
import {IWarehouseRegistry} from "../interfaces/IWarehouseRegistry.sol";
import {IAttestationRegistry} from "../interfaces/IAttestationRegistry.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";

/// @title RedemptionManager (C-08)
/// @notice Implements "no burn, no release".
///   1. Holder: requestRedemption(tokenId, keccak256(secret)) -> lot becomes REDEEMING (non-transferable).
///   2. Off-chain: warehouse gate releases goods only to a driver presenting a secret matching collectorHash.
///   3. Warehouse operator: confirmRelease(...) -> token burned + RELEASE attestation.
///   Holder may cancel before release, or raise a dispute after the SLA deadline. A dispute is a FLAG for
///   human review (ops may then freeze the warehouse in C-03). It does not auto-freeze: otherwise any holder
///   could freeze a whole warehouse by requesting redemption and never sending a collector.
contract RedemptionManager is TensileAccessControlled {
    enum Status {
        NONE,
        PENDING,
        RELEASED,
        CANCELLED,
        DISPUTED
    }

    struct Redemption {
        address holder;
        uint64 requestedAt;
        uint64 deadline;
        Status status;
        bytes32 collectorHash;
    }

    IMaterialPassport public immutable passport;
    IWarehouseRegistry public immutable warehouses;
    IAttestationRegistry public immutable attestations;
    IIdentityRegistry public immutable identity;

    uint64 public releaseSla = 72 hours;
    mapping(uint256 => Redemption) private _redemptions;

    event RedemptionRequested(
        uint256 indexed tokenId,
        uint32 indexed warehouseId,
        address indexed holder,
        bytes32 collectorHash,
        uint64 deadline
    );
    event RedemptionCancelled(uint256 indexed tokenId);
    event Redeemed(uint256 indexed tokenId, address indexed operator, bytes32 releaseProofHash);
    event RedemptionDisputed(uint256 indexed tokenId, uint32 indexed warehouseId);
    event SlaSet(uint64 sla);

    error NotHolder();
    error NotOperator();
    error NotVerified(address account);
    error WarehouseIsFrozen(uint32 warehouseId);
    error BadStatus(uint256 tokenId, Status status);
    error InvalidCollectorHash();
    error DeadlineNotReached();
    error InvalidSla();

    constructor(
        ITensileAccess access_,
        IMaterialPassport passport_,
        IWarehouseRegistry warehouses_,
        IAttestationRegistry attestations_,
        IIdentityRegistry identity_
    ) TensileAccessControlled(access_) {
        if (
            address(passport_) == address(0) || address(warehouses_) == address(0)
                || address(attestations_) == address(0) || address(identity_) == address(0)
        ) revert ZeroAddress();
        passport = passport_;
        warehouses = warehouses_;
        attestations = attestations_;
        identity = identity_;
    }

    function setReleaseSla(uint64 sla) external onlyAdmin {
        if (sla < 5 minutes || sla > 30 days) revert InvalidSla();
        releaseSla = sla;
        emit SlaSet(sla);
    }

    /// @param collectorHash keccak256 of a secret the holder hands to its collector. Never put the secret on-chain.
    function requestRedemption(uint256 tokenId, bytes32 collectorHash) external {
        if (collectorHash == bytes32(0)) revert InvalidCollectorHash();
        if (passport.ownerOf(tokenId) != msg.sender) revert NotHolder();
        if (!identity.isVerified(msg.sender)) revert NotVerified(msg.sender);
        uint32 wid = passport.lotOf(tokenId).warehouseId;
        if (warehouses.isFrozen(wid)) revert WarehouseIsFrozen(wid);

        Status s = _redemptions[tokenId].status;
        if (s == Status.PENDING || s == Status.DISPUTED) revert BadStatus(tokenId, s);

        passport.setRedeeming(tokenId); // reverts unless FREE

        uint64 deadline = uint64(block.timestamp) + releaseSla;
        _redemptions[tokenId] = Redemption({
            holder: msg.sender,
            requestedAt: uint64(block.timestamp),
            deadline: deadline,
            status: Status.PENDING,
            collectorHash: collectorHash
        });
        emit RedemptionRequested(tokenId, wid, msg.sender, collectorHash, deadline);
    }

    function cancelRedemption(uint256 tokenId) external {
        Redemption storage r = _redemptions[tokenId];
        if (r.status != Status.PENDING && r.status != Status.DISPUTED) revert BadStatus(tokenId, r.status);
        if (msg.sender != r.holder) revert NotHolder();
        r.status = Status.CANCELLED;
        passport.clearRedeeming(tokenId);
        emit RedemptionCancelled(tokenId);
    }

    /// @notice Warehouse operator confirms the goods left the gate. Burns the token (outstanding tonnage drops).
    /// @dev Allowed even if the warehouse is frozen: releasing to the rightful holder reduces exposure.
    function confirmRelease(uint256 tokenId, bytes32 releaseProofHash, string calldata uri) external {
        Redemption storage r = _redemptions[tokenId];
        if (r.status != Status.PENDING && r.status != Status.DISPUTED) revert BadStatus(tokenId, r.status);
        uint32 wid = passport.lotOf(tokenId).warehouseId;
        if (msg.sender != warehouses.operatorOf(wid)) revert NotOperator();

        r.status = Status.RELEASED;
        passport.burn(tokenId);
        attestations.record(
            IAttestationRegistry.Kind.RELEASE,
            IAttestationRegistry.SubjectType.LOT,
            tokenId,
            msg.sender,
            releaseProofHash,
            uri
        );
        emit Redeemed(tokenId, msg.sender, releaseProofHash);
    }

    /// @notice Holder escalates after the SLA. Emits an event for the Ops console; humans decide on a freeze.
    function raiseDispute(uint256 tokenId) external {
        Redemption storage r = _redemptions[tokenId];
        if (r.status != Status.PENDING) revert BadStatus(tokenId, r.status);
        if (msg.sender != r.holder) revert NotHolder();
        if (block.timestamp <= r.deadline) revert DeadlineNotReached();
        r.status = Status.DISPUTED;
        emit RedemptionDisputed(tokenId, passport.lotOf(tokenId).warehouseId);
    }

    function redemptionOf(uint256 tokenId) external view returns (Redemption memory) {
        return _redemptions[tokenId];
    }
}
