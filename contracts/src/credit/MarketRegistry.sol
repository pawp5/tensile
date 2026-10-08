// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoLib} from "morpho-blue/libraries/periphery/MorphoLib.sol";
import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {IMarketRegistry} from "../interfaces/IMarketRegistry.sol";
import {IMaterialPassport} from "../interfaces/IMaterialPassport.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {LotWrapper} from "./LotWrapper.sol";
import {Roles} from "../access/Roles.sol";

/// @title MarketRegistry (C-12)
/// @notice Connects Tensile lots to Morpho Blue.
///         - Risk config per CLASS (materialCode, warehouseId): oracle, LLTV, router LTV cap, attestation age.
///         - Per LOT: deploys a LotWrapper (C-14) and creates an isolated Morpho market
///           {loanToken, collateral = wrapper, oracle = class oracle, irm, lltv}.
///         Agents (A-4) may PROPOSE class configs; RISK_ADMIN approves.
/// @dev Morpho market params are immutable: changing a class later only affects lots whose market is created after.
contract MarketRegistry is IMarketRegistry, TensileAccessControlled {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;

    struct Proposal {
        bytes32 materialCode;
        uint32 warehouseId;
        address proposer;
        bool executed;
        ClassConfig config;
    }

    uint256 public constant MAX_LLTV = 0.9e18;

    IMorpho public immutable morpho;
    address public immutable loanToken;
    address public immutable irm;
    IMaterialPassport public immutable passport;
    IIdentityRegistry public immutable identity;
    address public router; // C-15, set once

    mapping(bytes32 => ClassConfig) private _classes;
    mapping(uint256 => address) public wrapperOf;
    mapping(address => uint256) public tokenIdOfWrapper;
    mapping(uint256 => MarketParams) private _lotMarket;

    uint256 public proposalCount;
    mapping(uint256 => Proposal) private _proposals;

    event ClassSet(bytes32 indexed classKey, bytes32 materialCode, uint32 warehouseId, ClassConfig config);
    event ClassProposed(uint256 indexed proposalId, bytes32 materialCode, uint32 warehouseId, address proposer);
    event ClassApproved(uint256 indexed proposalId, address approver);
    event LotMarketCreated(uint256 indexed tokenId, address indexed wrapper, Id indexed marketId);
    event RouterSet(address router);

    error InvalidConfig();
    error ClassDisabled(bytes32 classKey);
    error UnknownLot(uint256 tokenId);
    error NoMarket(uint256 tokenId);
    error BadProposal(uint256 proposalId);
    error AlreadySet();
    error RouterNotSet();

    constructor(
        ITensileAccess access_,
        IMorpho morpho_,
        address loanToken_,
        address irm_,
        IMaterialPassport passport_,
        IIdentityRegistry identity_
    ) TensileAccessControlled(access_) {
        if (
            address(morpho_) == address(0) || loanToken_ == address(0) || irm_ == address(0)
                || address(passport_) == address(0) || address(identity_) == address(0)
        ) revert ZeroAddress();
        if (!morpho_.isIrmEnabled(irm_)) revert InvalidConfig();
        morpho = morpho_;
        loanToken = loanToken_;
        irm = irm_;
        passport = passport_;
        identity = identity_;
    }

    /// @notice One-time wiring of C-15. Wrappers only accept Morpho deposits coming from this router.
    function setRouter(address router_) external onlyAdmin {
        if (router_ == address(0)) revert ZeroAddress();
        if (router != address(0)) revert AlreadySet();
        router = router_;
        emit RouterSet(router_);
    }

    // ------------------------------------------------------------------ class config

    function setClass(bytes32 materialCode, uint32 warehouseId, ClassConfig calldata cfg)
        external
        onlyRole(Roles.RISK_ADMIN)
    {
        _setClass(materialCode, warehouseId, cfg);
    }

    function proposeClass(bytes32 materialCode, uint32 warehouseId, ClassConfig calldata cfg)
        external
        returns (uint256 id)
    {
        if (!_hasRole(Roles.AI_AGENT, msg.sender) && !_hasRole(Roles.RISK_ADMIN, msg.sender)) {
            revert Unauthorized(msg.sender, Roles.AI_AGENT);
        }
        _validate(cfg);
        id = ++proposalCount;
        _proposals[id] = Proposal({
            materialCode: materialCode,
            warehouseId: warehouseId,
            proposer: msg.sender,
            executed: false,
            config: cfg
        });
        emit ClassProposed(id, materialCode, warehouseId, msg.sender);
    }

    function approveClass(uint256 proposalId) external onlyRole(Roles.RISK_ADMIN) {
        Proposal storage p = _proposals[proposalId];
        if (p.proposer == address(0) || p.executed) revert BadProposal(proposalId);
        p.executed = true;
        _setClass(p.materialCode, p.warehouseId, p.config);
        emit ClassApproved(proposalId, msg.sender);
    }

    function _setClass(bytes32 materialCode, uint32 warehouseId, ClassConfig memory cfg) internal {
        _validate(cfg);
        bytes32 key = classKey(materialCode, warehouseId);
        _classes[key] = cfg;
        emit ClassSet(key, materialCode, warehouseId, cfg);
    }

    function _validate(ClassConfig memory cfg) internal view {
        if (cfg.oracle == address(0)) revert InvalidConfig();
        if (cfg.lltv == 0 || cfg.lltv > MAX_LLTV || !morpho.isLltvEnabled(cfg.lltv)) revert InvalidConfig();
        // router cap (bps -> WAD) must be strictly below the liquidation LTV
        if (cfg.routerMaxLtvBps == 0 || uint256(cfg.routerMaxLtvBps) * 1e14 >= cfg.lltv) revert InvalidConfig();
        if (cfg.maxAttestationAge == 0) revert InvalidConfig();
    }

    // ------------------------------------------------------------------ lot markets

    /// @notice Idempotent: deploys the lot's wrapper and Morpho market on first call; returns stored params after.
    ///         Permissionless so lenders can open a market before the borrower arrives.
    function ensureLotMarket(uint256 tokenId) external returns (MarketParams memory params) {
        address existing = wrapperOf[tokenId];
        if (existing != address(0)) return _lotMarket[tokenId];

        if (router == address(0)) revert RouterNotSet();
        IMaterialPassport.Lot memory lot = passport.lotOf(tokenId);
        if (lot.state == IMaterialPassport.LotState.NONE) revert UnknownLot(tokenId);
        bytes32 key = classKey(lot.materialCode, lot.warehouseId);
        ClassConfig memory cfg = _classes[key];
        if (!cfg.enabled) revert ClassDisabled(key);

        string memory idStr = Strings.toString(tokenId);
        LotWrapper wrapper = new LotWrapper(
            access,
            passport,
            identity,
            tokenId,
            address(morpho),
            router,
            string.concat("Tensile Lot #", idStr),
            string.concat("TLOT-", idStr)
        );
        address w = address(wrapper);
        wrapperOf[tokenId] = w;
        tokenIdOfWrapper[w] = tokenId;
        identity.setProtocol(w, true); // the wrapper must be allowed to hold the lot NFT

        params = MarketParams({loanToken: loanToken, collateralToken: w, oracle: cfg.oracle, irm: irm, lltv: cfg.lltv});
        _lotMarket[tokenId] = params;

        Id id = params.id();
        if (morpho.lastUpdate(id) == 0) morpho.createMarket(params);
        emit LotMarketCreated(tokenId, w, id);
    }

    // ------------------------------------------------------------------ views

    function classKey(bytes32 materialCode, uint32 warehouseId) public pure returns (bytes32) {
        return keccak256(abi.encode(materialCode, warehouseId));
    }

    function getClass(bytes32 materialCode, uint32 warehouseId) external view returns (ClassConfig memory) {
        return _classes[classKey(materialCode, warehouseId)];
    }

    function classOf(uint256 tokenId) external view returns (ClassConfig memory) {
        IMaterialPassport.Lot memory lot = passport.lotOf(tokenId);
        return _classes[classKey(lot.materialCode, lot.warehouseId)];
    }

    function marketParamsOf(uint256 tokenId) external view returns (MarketParams memory) {
        if (wrapperOf[tokenId] == address(0)) revert NoMarket(tokenId);
        return _lotMarket[tokenId];
    }

    function marketIdOf(uint256 tokenId) external view returns (Id) {
        if (wrapperOf[tokenId] == address(0)) revert NoMarket(tokenId);
        MarketParams memory p = _lotMarket[tokenId];
        return p.id();
    }

    function isWrapper(address account) external view returns (bool) {
        return tokenIdOfWrapper[account] != 0;
    }

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }
}
