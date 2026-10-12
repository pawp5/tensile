// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IMaterialPassport} from "../interfaces/IMaterialPassport.sol";
import {IWarehouseRegistry} from "../interfaces/IWarehouseRegistry.sol";
import {IAttestationRegistry} from "../interfaces/IAttestationRegistry.sol";
import {IReserveGuard} from "../interfaces/IReserveGuard.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {IFeeCollector} from "../interfaces/IFeeCollector.sol";
import {Roles} from "../access/Roles.sol";

/// @title MintingController (C-07)
/// @notice "Physical first, legal second, token last." A lot is minted only when ALL of these hold:
///         custody confirmed by the warehouse operator, an inspector attestation, an AI review above threshold
///         (or a human override), and a fresh reserve report covering outstanding + new quantity.
contract MintingController is TensileAccessControlled {
    using SafeERC20 for IERC20;

    enum Status {
        NONE,
        REQUESTED,
        FINALIZED,
        REJECTED,
        CANCELLED,
        EXPIRED
    }

    struct MintRequest {
        address owner;
        uint32 warehouseId;
        uint96 quantityKg;
        uint64 createdAt;
        uint64 custodyAt;
        Status status;
        bool aiOverride;
        bytes32 materialCode;
        bytes32 certHash;
        string evidenceURI;
        uint256 tokenId;
    }

    bytes32 public constant FEE_MINT = keccak256("MINT");

    IMaterialPassport public immutable passport;
    IWarehouseRegistry public immutable warehouses;
    IAttestationRegistry public immutable attestations;
    IReserveGuard public immutable guard;
    IIdentityRegistry public immutable identity;

    IERC20 public feeToken;
    IFeeCollector public feeCollector;
    uint256 public mintFee; // in feeToken units, 0 = free
    uint64 public requestTTL = 14 days;
    uint16 public minAiScore = 70;

    uint256 public requestCount;
    mapping(uint256 => MintRequest) private _requests;
    /// @dev certHash => open requestId (prevents two simultaneous requests for one certificate)
    mapping(bytes32 => uint256) public pendingCertRequest;

    event MintRequested(
        uint256 indexed requestId,
        address indexed owner,
        uint32 indexed warehouseId,
        bytes32 materialCode,
        uint96 quantityKg,
        bytes32 certHash,
        string evidenceURI
    );
    event CustodyConfirmed(uint256 indexed requestId, address indexed operator);
    event AiOverridden(uint256 indexed requestId, address indexed by);
    event MintFinalized(uint256 indexed requestId, uint256 indexed tokenId);
    event MintRejected(uint256 indexed requestId, address indexed by, bytes32 reason);
    event MintCancelled(uint256 indexed requestId);
    event MintExpired(uint256 indexed requestId);
    event ParamsSet(uint64 requestTTL, uint16 minAiScore);
    event FeeSet(address token, address collector, uint256 fee);

    error NotVerified(address account);
    error WarehouseUnavailable(uint32 warehouseId);
    error InvalidRequest();
    error CertificateUnavailable(bytes32 certHash);
    error BadStatus(uint256 requestId, Status status);
    error RequestExpired(uint256 requestId);
    error NotYetExpired(uint256 requestId);
    error NotOperator();
    error NotOwner();
    error AlreadyConfirmed();
    error MissingCustody();
    error MissingInspection();
    error AiReviewInsufficient(uint16 score);
    error ReserveInsufficient(uint32 warehouseId);
    error InvalidParams();

    constructor(
        ITensileAccess access_,
        IMaterialPassport passport_,
        IWarehouseRegistry warehouses_,
        IAttestationRegistry attestations_,
        IReserveGuard guard_,
        IIdentityRegistry identity_
    ) TensileAccessControlled(access_) {
        if (
            address(passport_) == address(0) || address(warehouses_) == address(0)
                || address(attestations_) == address(0) || address(guard_) == address(0)
                || address(identity_) == address(0)
        ) revert ZeroAddress();
        passport = passport_;
        warehouses = warehouses_;
        attestations = attestations_;
        guard = guard_;
        identity = identity_;
    }

    // ------------------------------------------------------------------ admin

    function setParams(uint64 ttl, uint16 minScore) external onlyAdmin {
        if (ttl < 1 hours || ttl > 90 days || minScore > 100) revert InvalidParams();
        requestTTL = ttl;
        minAiScore = minScore;
        emit ParamsSet(ttl, minScore);
    }

    function setFee(IERC20 token, IFeeCollector collector, uint256 fee) external onlyAdmin {
        if (fee != 0 && (address(token) == address(0) || address(collector) == address(0))) revert ZeroAddress();
        feeToken = token;
        feeCollector = collector;
        mintFee = fee;
        emit FeeSet(address(token), address(collector), fee);
    }

    // ------------------------------------------------------------------ lifecycle

    /// @notice Step 1 — material owner opens a request after uploading evidence to IPFS.
    function requestMint(
        uint32 warehouseId,
        bytes32 materialCode,
        uint96 quantityKg,
        bytes32 certHash,
        string calldata evidenceURI
    ) external returns (uint256 requestId) {
        if (!identity.isVerified(msg.sender)) revert NotVerified(msg.sender);
        if (!warehouses.isActive(warehouseId) || warehouses.isFrozen(warehouseId)) {
            revert WarehouseUnavailable(warehouseId);
        }
        if (quantityKg == 0 || materialCode == bytes32(0) || certHash == bytes32(0)) revert InvalidRequest();
        if (passport.certUsed(certHash) || pendingCertRequest[certHash] != 0) revert CertificateUnavailable(certHash);

        requestId = ++requestCount;
        _requests[requestId] = MintRequest({
            owner: msg.sender,
            warehouseId: warehouseId,
            quantityKg: quantityKg,
            createdAt: uint64(block.timestamp),
            custodyAt: 0,
            status: Status.REQUESTED,
            aiOverride: false,
            materialCode: materialCode,
            certHash: certHash,
            evidenceURI: evidenceURI,
            tokenId: 0
        });
        pendingCertRequest[certHash] = requestId;

        if (mintFee != 0) {
            feeToken.safeTransferFrom(msg.sender, address(feeCollector), mintFee);
            feeCollector.notify(FEE_MINT, address(feeToken), mintFee, requestId);
        }

        emit MintRequested(requestId, msg.sender, warehouseId, materialCode, quantityKg, certHash, evidenceURI);
    }

    /// @notice Step 2 — the warehouse operator confirms the material is physically in custody.
    function confirmCustody(uint256 requestId, bytes32 dataHash, string calldata uri) external {
        MintRequest storage r = _openRequest(requestId);
        if (msg.sender != warehouses.operatorOf(r.warehouseId)) revert NotOperator();
        if (r.custodyAt != 0) revert AlreadyConfirmed();
        r.custodyAt = uint64(block.timestamp);
        attestations.record(
            IAttestationRegistry.Kind.CUSTODY,
            IAttestationRegistry.SubjectType.REQUEST,
            requestId,
            msg.sender,
            dataHash,
            uri
        );
        emit CustodyConfirmed(requestId, msg.sender);
    }

    // Step 3 (inspection) and step 4 (AI review) are written directly to C-05 by INSPECTOR / AI_AGENT.

    /// @notice Human override when the AI score is low but a reviewer has checked the documents.
    function overrideAi(uint256 requestId) external onlyRole(Roles.RISK_ADMIN) {
        MintRequest storage r = _openRequest(requestId);
        r.aiOverride = true;
        emit AiOverridden(requestId, msg.sender);
    }

    /// @notice Step 5 — anyone can finalize once every condition holds. Mints the passport to the owner.
    function finalizeMint(uint256 requestId) external returns (uint256 tokenId) {
        MintRequest storage r = _openRequest(requestId);

        if (r.custodyAt == 0) revert MissingCustody();

        IAttestationRegistry.Attestation memory insp = attestations.latest(
            IAttestationRegistry.Kind.INSPECTION, IAttestationRegistry.SubjectType.REQUEST, requestId
        );
        if (insp.attestor == address(0)) revert MissingInspection();

        if (!r.aiOverride) {
            IAttestationRegistry.Attestation memory ai = attestations.latest(
                IAttestationRegistry.Kind.AI_REVIEW, IAttestationRegistry.SubjectType.REQUEST, requestId
            );
            if (ai.attestor == address(0) || ai.score < minAiScore) revert AiReviewInsufficient(ai.score);
        }

        if (warehouses.isFrozen(r.warehouseId)) revert WarehouseUnavailable(r.warehouseId);
        if (!guard.canAdd(r.warehouseId, r.quantityKg)) revert ReserveInsufficient(r.warehouseId);
        if (!identity.isVerified(r.owner)) revert NotVerified(r.owner);

        r.status = Status.FINALIZED;
        delete pendingCertRequest[r.certHash];

        tokenId = passport.mint(r.owner, r.materialCode, r.warehouseId, r.quantityKg, r.certHash, r.evidenceURI);
        r.tokenId = tokenId;
        emit MintFinalized(requestId, tokenId);
    }

    function rejectRequest(uint256 requestId, bytes32 reason) external {
        MintRequest storage r = _requests[requestId];
        if (r.status != Status.REQUESTED) revert BadStatus(requestId, r.status);
        bool allowed = _hasRole(Roles.RISK_ADMIN, msg.sender) || _hasRole(Roles.INSPECTOR, msg.sender)
            || msg.sender == warehouses.operatorOf(r.warehouseId);
        if (!allowed) revert Unauthorized(msg.sender, Roles.RISK_ADMIN);
        r.status = Status.REJECTED;
        delete pendingCertRequest[r.certHash];
        emit MintRejected(requestId, msg.sender, reason);
    }

    function cancelRequest(uint256 requestId) external {
        MintRequest storage r = _requests[requestId];
        if (r.status != Status.REQUESTED) revert BadStatus(requestId, r.status);
        if (msg.sender != r.owner) revert NotOwner();
        r.status = Status.CANCELLED;
        delete pendingCertRequest[r.certHash];
        emit MintCancelled(requestId);
    }

    /// @notice Anyone can expire a stale request to release its certificate hash.
    function expireRequest(uint256 requestId) external {
        MintRequest storage r = _requests[requestId];
        if (r.status != Status.REQUESTED) revert BadStatus(requestId, r.status);
        if (block.timestamp <= uint256(r.createdAt) + requestTTL) revert NotYetExpired(requestId);
        r.status = Status.EXPIRED;
        delete pendingCertRequest[r.certHash];
        emit MintExpired(requestId);
    }

    // ------------------------------------------------------------------ views

    function getRequest(uint256 requestId) external view returns (MintRequest memory) {
        return _requests[requestId];
    }

    function _openRequest(uint256 requestId) internal view returns (MintRequest storage r) {
        r = _requests[requestId];
        if (r.status != Status.REQUESTED) revert BadStatus(requestId, r.status);
        if (block.timestamp > uint256(r.createdAt) + requestTTL) revert RequestExpired(requestId);
    }
}
