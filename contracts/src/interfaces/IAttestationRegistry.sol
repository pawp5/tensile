// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAttestationRegistry (C-05)
interface IAttestationRegistry {
    enum Kind {
        CUSTODY,
        INSPECTION,
        REINSPECTION,
        AI_REVIEW,
        RELEASE
    }

    enum SubjectType {
        REQUEST,
        LOT
    }

    struct Attestation {
        Kind kind;
        SubjectType subjectType;
        uint16 score; // 0-100, only meaningful for AI_REVIEW
        address attestor;
        uint64 timestamp;
        uint256 subject;
        bytes32 dataHash;
        string uri;
    }

    function record(
        Kind kind,
        SubjectType subjectType,
        uint256 subject,
        address attestor,
        bytes32 dataHash,
        string calldata uri
    ) external returns (uint256 index);

    function latest(Kind kind, SubjectType subjectType, uint256 subject) external view returns (Attestation memory);
}
