// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IAttestationRegistry} from "../interfaces/IAttestationRegistry.sol";
import {IMaterialPassport} from "../interfaces/IMaterialPassport.sol";
import {Roles} from "../access/Roles.sol";

/// @title AttestationRegistry (C-05)
/// @notice Append-only evidence log. Every human or AI claim about a mint request or a lot is stored here
///         with the hash of its evidence file (stored off-chain on IPFS).
/// @dev  Who may write what:
///       INSPECTION   -> INSPECTOR role (subject: REQUEST or LOT)
///       REINSPECTION -> INSPECTOR role (subject: LOT only; refreshes C-06.lastAttestedAt)
///       AI_REVIEW    -> AI_AGENT role (score 0-100, advisory)
///       CUSTODY / RELEASE -> only through `record` by RECORDER contracts (C-07 / C-08), which have already
///                            verified that the caller is the warehouse operator.
contract AttestationRegistry is IAttestationRegistry, TensileAccessControlled {
    Attestation[] private _attestations;
    /// @dev keccak(kind, subjectType, subject) => index + 1 of the latest attestation (0 = none)
    mapping(bytes32 => uint256) private _latest;

    IMaterialPassport public passport;

    event Attested(
        uint256 indexed index,
        Kind indexed kind,
        SubjectType subjectType,
        uint256 indexed subject,
        address attestor,
        uint16 score,
        bytes32 dataHash,
        string uri
    );
    event PassportSet(address passport);

    error InvalidKind();
    error InvalidScore();
    error EmptyDataHash();
    error UnknownLot(uint256 tokenId);
    error PassportNotSet();

    constructor(ITensileAccess access_) TensileAccessControlled(access_) {}

    function setPassport(IMaterialPassport passport_) external onlyAdmin {
        if (address(passport_) == address(0)) revert ZeroAddress();
        passport = passport_;
        emit PassportSet(address(passport_));
    }

    /// @notice Direct attestation by inspectors and AI agents.
    function attest(
        Kind kind,
        SubjectType subjectType,
        uint256 subject,
        uint16 score,
        bytes32 dataHash,
        string calldata uri
    ) external returns (uint256 index) {
        if (kind == Kind.INSPECTION) {
            _checkRole(Roles.INSPECTOR);
            if (score != 0) revert InvalidScore();
        } else if (kind == Kind.REINSPECTION) {
            _checkRole(Roles.INSPECTOR);
            if (score != 0) revert InvalidScore();
            if (subjectType != SubjectType.LOT) revert InvalidKind();
        } else if (kind == Kind.AI_REVIEW) {
            _checkRole(Roles.AI_AGENT);
            if (score > 100) revert InvalidScore();
        } else {
            revert InvalidKind(); // CUSTODY and RELEASE only via record()
        }

        if (subjectType == SubjectType.LOT) {
            if (address(passport) == address(0)) revert PassportNotSet();
            if (!passport.exists(subject)) revert UnknownLot(subject);
        }

        index = _store(kind, subjectType, subject, msg.sender, score, dataHash, uri);

        if (kind == Kind.REINSPECTION || (kind == Kind.INSPECTION && subjectType == SubjectType.LOT)) {
            passport.recordAttestation(subject);
        }
    }

    /// @inheritdoc IAttestationRegistry
    function record(
        Kind kind,
        SubjectType subjectType,
        uint256 subject,
        address attestor,
        bytes32 dataHash,
        string calldata uri
    ) external onlyRole(Roles.RECORDER) returns (uint256 index) {
        if (kind != Kind.CUSTODY && kind != Kind.RELEASE) revert InvalidKind();
        index = _store(kind, subjectType, subject, attestor, 0, dataHash, uri);
    }

    function _store(
        Kind kind,
        SubjectType subjectType,
        uint256 subject,
        address attestor,
        uint16 score,
        bytes32 dataHash,
        string calldata uri
    ) internal returns (uint256 index) {
        if (dataHash == bytes32(0)) revert EmptyDataHash();
        index = _attestations.length;
        _attestations.push(
            Attestation({
                kind: kind,
                subjectType: subjectType,
                score: score,
                attestor: attestor,
                timestamp: uint64(block.timestamp),
                subject: subject,
                dataHash: dataHash,
                uri: uri
            })
        );
        _latest[_key(kind, subjectType, subject)] = index + 1;
        emit Attested(index, kind, subjectType, subject, attestor, score, dataHash, uri);
    }

    // ------------------------------------------------------------------ views

    /// @return a The latest attestation of that kind for that subject, or an empty struct (attestor == 0) if none.
    function latest(Kind kind, SubjectType subjectType, uint256 subject) external view returns (Attestation memory a) {
        uint256 i = _latest[_key(kind, subjectType, subject)];
        if (i != 0) a = _attestations[i - 1];
    }

    function attestationAt(uint256 index) external view returns (Attestation memory) {
        return _attestations[index];
    }

    function count() external view returns (uint256) {
        return _attestations.length;
    }

    function _key(Kind kind, SubjectType subjectType, uint256 subject) internal pure returns (bytes32) {
        return keccak256(abi.encode(kind, subjectType, subject));
    }
}
