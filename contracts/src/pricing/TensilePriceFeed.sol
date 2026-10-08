// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {Roles} from "../access/Roles.sol";

/// @title TensilePriceFeed (C-11a)
/// @notice Reference price for ONE (material, region) pair in USD per tonne, 8 decimals.
///         Pushed by agent A-5 (PRICE_UPDATER) within a max-deviation bound; larger moves need RISK_ADMIN.
///         Exposes Chainlink's AggregatorV3Interface so it can later be replaced by a licensed Chainlink feed.
contract TensilePriceFeed is IAggregatorV3, TensileAccessControlled {
    struct Round {
        int256 answer;
        uint64 updatedAt;
    }

    uint8 public constant DECIMALS = 8;
    string private _description;
    uint16 public maxDeviationBps = 1_000; // 10% per update
    /// @dev Bounds how fast the agent can walk the price: at most maxDeviationBps per minUpdateInterval.
    uint32 public minUpdateInterval = 10 minutes;
    uint80 public latestRound;
    mapping(uint80 => Round) private _rounds;

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event MaxDeviationSet(uint16 bps);
    event MinUpdateIntervalSet(uint32 interval);

    error InvalidPrice();
    error DeviationTooLarge(int256 previous, int256 next);
    error InvalidDeviation();
    error NoData();
    error TooSoon(uint256 nextAllowed);

    constructor(ITensileAccess access_, string memory description_) TensileAccessControlled(access_) {
        _description = description_;
    }

    function setMaxDeviationBps(uint16 bps) external onlyAdmin {
        if (bps == 0 || bps > 10_000) revert InvalidDeviation();
        maxDeviationBps = bps;
        emit MaxDeviationSet(bps);
    }

    function setMinUpdateInterval(uint32 interval) external onlyAdmin {
        minUpdateInterval = interval;
        emit MinUpdateIntervalSet(interval);
    }

    /// @notice Regular update by the price agent. First update is unbounded.
    function update(int256 price) external onlyRole(Roles.PRICE_UPDATER) {
        if (price <= 0) revert InvalidPrice();
        if (latestRound != 0) {
            uint256 next = uint256(_rounds[latestRound].updatedAt) + minUpdateInterval;
            if (block.timestamp < next) revert TooSoon(next);
            int256 prev = _rounds[latestRound].answer;
            int256 diff = price > prev ? price - prev : prev - price;
            if (diff * 10_000 > prev * int256(uint256(maxDeviationBps))) revert DeviationTooLarge(prev, price);
        }
        _push(price);
    }

    /// @notice Human-approved update that bypasses the deviation bound (e.g. genuine market shock).
    function forceUpdate(int256 price) external onlyRole(Roles.RISK_ADMIN) {
        if (price <= 0) revert InvalidPrice();
        _push(price);
    }

    function _push(int256 price) internal {
        uint80 id = ++latestRound;
        _rounds[id] = Round({answer: price, updatedAt: uint64(block.timestamp)});
        emit AnswerUpdated(price, id, block.timestamp);
    }

    function decimals() external pure returns (uint8) {
        return DECIMALS;
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
        return (roundId, r.answer, r.updatedAt, r.updatedAt, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint80 id = latestRound;
        Round memory r = _rounds[id];
        return (id, r.answer, r.updatedAt, r.updatedAt, id);
    }
}
