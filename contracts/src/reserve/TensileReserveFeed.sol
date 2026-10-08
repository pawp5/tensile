// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// @title TensileReserveFeed (C-09)
/// @notice Proof-of-Reserve feed for ONE warehouse: kilograms of verified material on hand.
///         Implements Chainlink's AggregatorV3Interface, so it is a drop-in replacement target for an
///         official Chainlink PoR feed (swap the address in C-03, no consumer changes).
/// @dev Each report must be co-signed (EIP-712) by the warehouse signer AND the inspector signer.
///      Anyone may relay a valid report (normally agent A-3).
contract TensileReserveFeed is IAggregatorV3, EIP712, TensileAccessControlled {
    struct Round {
        int256 answer;
        uint64 observedAt;
        uint64 submittedAt;
    }

    bytes32 public constant REPORT_TYPEHASH =
        keccak256("ReserveReport(uint32 warehouseId,int256 reserveKg,uint64 observedAt)");

    uint32 public immutable warehouseId;
    string private _description;

    address public warehouseSigner;
    address public inspectorSigner;
    uint80 public latestRound;
    uint64 public lastObservedAt;
    /// @dev Reports showing a drop larger than this (bps of previous answer) emit LargeDrop for alerting.
    uint16 public largeDropBps = 1_000;

    mapping(uint80 => Round) private _rounds;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event NewRound(uint256 indexed roundId, address indexed startedBy, uint256 startedAt);
    event LargeDrop(uint80 indexed roundId, int256 previous, int256 current);
    event SignersSet(address warehouseSigner, address inspectorSigner);

    error InvalidSigners();
    error InvalidReserve();
    error InvalidTimestamp();
    error BadSignature(address expected);
    error NoData();

    constructor(
        ITensileAccess access_,
        uint32 warehouseId_,
        string memory description_,
        address warehouseSigner_,
        address inspectorSigner_
    ) EIP712("TensileReserveFeed", "1") TensileAccessControlled(access_) {
        warehouseId = warehouseId_;
        _description = description_;
        _setSigners(warehouseSigner_, inspectorSigner_);
    }

    function setSigners(address warehouseSigner_, address inspectorSigner_) external onlyAdmin {
        _setSigners(warehouseSigner_, inspectorSigner_);
    }

    function setLargeDropBps(uint16 bps) external onlyAdmin {
        largeDropBps = bps;
    }

    /// @notice Submit a co-signed reserve report.
    function submit(int256 reserveKg, uint64 observedAt, bytes calldata warehouseSig, bytes calldata inspectorSig)
        external
        returns (uint80 roundId)
    {
        if (reserveKg < 0) revert InvalidReserve();
        if (observedAt <= lastObservedAt || observedAt > block.timestamp) revert InvalidTimestamp();

        bytes32 digest = reportDigest(reserveKg, observedAt);
        if (ECDSA.recover(digest, warehouseSig) != warehouseSigner) revert BadSignature(warehouseSigner);
        if (ECDSA.recover(digest, inspectorSig) != inspectorSigner) revert BadSignature(inspectorSigner);

        int256 previous = latestRound == 0 ? int256(0) : _rounds[latestRound].answer;

        lastObservedAt = observedAt;
        roundId = ++latestRound;
        _rounds[roundId] = Round({answer: reserveKg, observedAt: observedAt, submittedAt: uint64(block.timestamp)});

        emit NewRound(roundId, msg.sender, observedAt);
        emit AnswerUpdated(reserveKg, roundId, observedAt);
        if (previous > 0 && reserveKg < previous && (previous - reserveKg) * 10_000 > previous * int256(uint256(largeDropBps))) {
            emit LargeDrop(roundId, previous, reserveKg);
        }
    }

    /// @notice EIP-712 digest both signers must sign. Exposed so off-chain signers (A-3, S-4) can compute it.
    function reportDigest(int256 reserveKg, uint64 observedAt) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(REPORT_TYPEHASH, warehouseId, reserveKg, observedAt)));
    }

    // ------------------------------------------------------------------ AggregatorV3Interface

    function decimals() external pure returns (uint8) {
        return 0; // kilograms
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (roundId == 0 || roundId > latestRound) revert NoData();
        Round memory r = _rounds[roundId];
        return (roundId, r.answer, r.observedAt, r.observedAt, roundId);
    }

    /// @dev Returns all zeros before the first report (consumers treat updatedAt == 0 as stale).
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint80 id = latestRound;
        Round memory r = _rounds[id];
        return (id, r.answer, r.observedAt, r.observedAt, id);
    }

    function _setSigners(address w, address i) internal {
        if (w == address(0) || i == address(0) || w == i) revert InvalidSigners();
        warehouseSigner = w;
        inspectorSigner = i;
        emit SignersSet(w, i);
    }
}
