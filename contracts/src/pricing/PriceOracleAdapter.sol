// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IPriceOracleAdapter} from "../interfaces/IPriceOracleAdapter.sol";
import {IMaterialPassport} from "../interfaces/IMaterialPassport.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {Roles} from "../access/Roles.sol";

/// @title PriceOracleAdapter (C-11b)
/// @notice THE single place where lots are valued. Nobody else re-implements valuation.
///         price = feed(material, region) normalised to 8 decimals, minus regional haircut.
///         lotValue = quantityKg * price / 1000, expressed in loan-token units.
contract PriceOracleAdapter is IPriceOracleAdapter, TensileAccessControlled {
    uint8 public constant PRICE_DECIMALS = 8;
    uint16 public constant MAX_HAIRCUT_BPS = 5_000;

    IMaterialPassport public immutable passport;
    uint8 public immutable loanTokenDecimals;

    mapping(bytes32 => mapping(bytes32 => address)) public feedOf; // materialCode => region => feed
    mapping(bytes32 => uint16) public haircutBps; // region => bps
    uint256 public maxPriceStaleness = 3 days;

    // Optional stablecoin de-peg guard (e.g. Chainlink USDC/USD on Monad).
    address public stableFeed;
    uint256 public stableFloor; // in stableFeed decimals, e.g. 0.98e8
    uint256 public stableMaxStaleness = 1 days;

    event FeedSet(bytes32 indexed materialCode, bytes32 indexed regionCode, address feed);
    event HaircutSet(bytes32 indexed regionCode, uint16 bps);
    event MaxPriceStalenessSet(uint256 s);
    event StableGuardSet(address feed, uint256 floor, uint256 maxStaleness);

    error NoFeed(bytes32 materialCode, bytes32 regionCode);
    error InvalidAnswer();
    error StalePrice(uint256 updatedAt);
    error InvalidHaircut();
    error InvalidParams();
    error UnknownLot(uint256 tokenId);
    error StablecoinDepeg(int256 answer);

    constructor(ITensileAccess access_, IMaterialPassport passport_, uint8 loanTokenDecimals_)
        TensileAccessControlled(access_)
    {
        if (address(passport_) == address(0)) revert ZeroAddress();
        if (loanTokenDecimals_ > 18) revert InvalidParams();
        passport = passport_;
        loanTokenDecimals = loanTokenDecimals_;
    }

    // ------------------------------------------------------------------ config

    function setFeed(bytes32 materialCode, bytes32 regionCode, address feed) external onlyRole(Roles.RISK_ADMIN) {
        feedOf[materialCode][regionCode] = feed;
        emit FeedSet(materialCode, regionCode, feed);
    }

    function setHaircut(bytes32 regionCode, uint16 bps) external onlyRole(Roles.RISK_ADMIN) {
        if (bps > MAX_HAIRCUT_BPS) revert InvalidHaircut();
        haircutBps[regionCode] = bps;
        emit HaircutSet(regionCode, bps);
    }

    function setMaxPriceStaleness(uint256 s) external onlyAdmin {
        if (s == 0) revert InvalidParams();
        maxPriceStaleness = s;
        emit MaxPriceStalenessSet(s);
    }

    function setStableGuard(address feed, uint256 floor, uint256 maxStaleness) external onlyAdmin {
        if (feed != address(0) && (floor == 0 || maxStaleness == 0)) revert InvalidParams();
        stableFeed = feed;
        stableFloor = floor;
        stableMaxStaleness = maxStaleness;
        emit StableGuardSet(feed, floor, maxStaleness);
    }

    // ------------------------------------------------------------------ views

    function pricePerTonne(bytes32 materialCode, bytes32 regionCode) public view returns (uint256) {
        address feed = feedOf[materialCode][regionCode];
        if (feed == address(0)) revert NoFeed(materialCode, regionCode);
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert InvalidAnswer();
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxPriceStaleness) {
            revert StalePrice(updatedAt);
        }
        uint256 p = _toDecimals(uint256(answer), IAggregatorV3(feed).decimals(), PRICE_DECIMALS);
        return p * (10_000 - haircutBps[regionCode]) / 10_000;
    }

    function lotValue(uint256 tokenId) external view returns (uint256) {
        IMaterialPassport.Lot memory lot = passport.lotOf(tokenId);
        if (lot.state == IMaterialPassport.LotState.NONE) revert UnknownLot(tokenId);
        uint256 p = pricePerTonne(lot.materialCode, lot.regionCode);
        // value = qtyKg/1000 tonnes * p / 1e8 USD * 10^dec
        return Math.mulDiv(uint256(lot.quantityKg) * p, 10 ** loanTokenDecimals, 1000 * 10 ** PRICE_DECIMALS);
    }

    function requireStablePeg() external view {
        address feed = stableFeed;
        if (feed == address(0)) return;
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0 || uint256(answer) < stableFloor) revert StablecoinDepeg(answer);
        if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > stableMaxStaleness) {
            revert StalePrice(updatedAt);
        }
    }

    function _toDecimals(uint256 v, uint8 from, uint8 to) internal pure returns (uint256) {
        if (from == to) return v;
        if (from > to) return v / 10 ** (from - to);
        return v * 10 ** (to - from);
    }
}
