// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMorpho, MarketParams, Id} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoLib} from "morpho-blue/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";

import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {ITensileCreditVault} from "../interfaces/ITensileCreditVault.sol";
import {IMarketRegistry} from "../interfaces/IMarketRegistry.sol";
import {IMaterialPassport} from "../interfaces/IMaterialPassport.sol";
import {IFeeCollector} from "../interfaces/IFeeCollector.sol";
import {Roles} from "../access/Roles.sol";

/// @title TensileCreditVault (C-14b)
/// @notice ERC-4626 USDC vault that aggregates lenders. Supplies to a lot's Morpho market just-in-time when
///         the router opens a loan, pulls it back on repay. Lenders see one share price (tUSDC) that
///         accrues as borrowers pay interest.
///
/// Accounting:
///   totalAssets = cash + totalSuppliedAssets - unrealised losses (losses are debited on `onLoss`).
///   totalSuppliedAssets is the sum of what the vault has supplied to all its lot markets, adjusted on every
///   repay and loss. It is also refreshed to real Morpho supply balances before any share-price operation
///   (deposit / mint / withdraw / redeem) by iterating tracked markets. Each lot market has at most one
///   borrower (the router's position) so iterating is bounded. A batch size cap prevents unbounded gas.
///
/// Fees (optional):
///   `reserveFactorBps` of interest paid on each repay is diverted to C-18 FeeCollector; the rest goes to lenders.
///
/// Freeze behaviour:
///   Borrowers can still `repay` when their lot's warehouse is frozen, so the vault keeps receiving liquidity.
///   Only new `supplyFor` from this vault is implicitly blocked (the router refuses to openLoan at a frozen
///   warehouse via its own checks).
contract TensileCreditVault is ITensileCreditVault, ERC4626, TensileAccessControlled, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    bytes32 public constant FEE_RESERVE = keccak256("RESERVE_FACTOR");
    uint16 public constant MAX_RESERVE_FACTOR_BPS = 3_000; // 30 %
    uint16 public constant MAX_BATCH = 100;

    IMorpho public immutable morpho;
    IMarketRegistry public immutable registry;
    IMaterialPassport public immutable passport;

    address public router; // set once
    IFeeCollector public feeCollector; // optional

    uint256 private _totalSuppliedAssets;
    mapping(uint256 => uint256) public suppliedForMarket; // tokenId => principal supplied
    mapping(bytes32 => uint256) public suppliedForClass; // classKey => principal supplied
    mapping(bytes32 => uint256) public classCap; // 0 = disabled, type(uint256).max = unlimited

    /// @dev Lots the vault has an open supply position in. Used to accrue + reconcile before share-price ops.
    uint256[] public activeMarkets;
    mapping(uint256 => uint256) private _activeIndexPlus1; // tokenId => index+1 in activeMarkets

    uint16 public reserveFactorBps; // 0 by default
    uint16 public accrueBatchSize = 20;

    event RouterSet(address router);
    event FeeConfigSet(address collector, uint16 bps);
    event AccrueBatchSizeSet(uint16 size);
    event ClassCapSet(bytes32 indexed classKey, uint256 cap);
    event Supplied(uint256 indexed tokenId, bytes32 indexed classKey, uint256 assets);
    event WithdrawnFromMarket(uint256 indexed tokenId, bytes32 indexed classKey, uint256 assets);
    event InterestAccrued(uint256 indexed tokenId, uint256 interest, uint256 fee);
    event PrincipalReturned(uint256 indexed tokenId, uint256 principal);
    event LossRealized(uint256 indexed tokenId, bytes32 indexed classKey, uint256 assets);

    error NotRouter();
    error AlreadySet();
    error InvalidFee();
    error InvalidBatch();
    error InsufficientCash(uint256 requested, uint256 cash);
    error ClassDisabled(bytes32 classKey);
    error ClassCapExceeded(bytes32 classKey, uint256 supplied, uint256 cap);
    error UnknownLot(uint256 tokenId);
    error LossExceedsPosition(uint256 tokenId, uint256 requested, uint256 recorded);

    constructor(ITensileAccess access_, IMorpho morpho_, IMarketRegistry registry_, IMaterialPassport passport_, IERC20 asset_)
        ERC20(
            string.concat("Tensile ", IERC20Metadata(address(asset_)).symbol(), " Vault"),
            string.concat("t", IERC20Metadata(address(asset_)).symbol())
        )
        ERC4626(asset_)
        TensileAccessControlled(access_)
    {
        if (
            address(morpho_) == address(0) || address(registry_) == address(0) || address(passport_) == address(0)
                || address(asset_) == address(0)
        ) revert ZeroAddress();
        morpho = morpho_;
        registry = registry_;
        passport = passport_;
    }

    // ------------------------------------------------------------------ admin

    function setRouter(address router_) external onlyAdmin {
        if (router_ == address(0)) revert ZeroAddress();
        if (router != address(0)) revert AlreadySet();
        router = router_;
        emit RouterSet(router_);
    }

    function setFeeConfig(IFeeCollector collector, uint16 bps) external onlyRole(Roles.RISK_ADMIN) {
        if (bps > MAX_RESERVE_FACTOR_BPS) revert InvalidFee();
        if (bps != 0 && address(collector) == address(0)) revert ZeroAddress();
        feeCollector = collector;
        reserveFactorBps = bps;
        emit FeeConfigSet(address(collector), bps);
    }

    function setAccrueBatchSize(uint16 size) external onlyAdmin {
        if (size == 0 || size > MAX_BATCH) revert InvalidBatch();
        accrueBatchSize = size;
        emit AccrueBatchSizeSet(size);
    }

    /// @notice Set the maximum USDC principal the vault may have outstanding in a (material, warehouse) class.
    ///         0 blocks new supply to that class (does not force a withdraw). Must be positive to enable it.
    function setClassCap(bytes32 classKey, uint256 cap) external onlyRole(Roles.RISK_ADMIN) {
        classCap[classKey] = cap;
        emit ClassCapSet(classKey, cap);
    }

    // ------------------------------------------------------------------ router hooks

    modifier onlyRouter() {
        if (msg.sender != router) revert NotRouter();
        _;
    }

    function supplyFor(uint256 tokenId, uint256 assets) external onlyRouter nonReentrant returns (uint256 supplied) {
        if (assets == 0) return 0;
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        if (cash < assets) revert InsufficientCash(assets, cash);

        (MarketParams memory params, bytes32 key) = _paramsAndKey(tokenId);
        uint256 cap = classCap[key];
        if (cap == 0) revert ClassDisabled(key);
        uint256 after_ = suppliedForClass[key] + assets;
        if (after_ > cap) revert ClassCapExceeded(key, after_, cap);

        _accrueAll();

        IERC20(asset()).forceApprove(address(morpho), assets);
        (uint256 assetsSupplied,) = morpho.supply(params, assets, 0, address(this), "");
        IERC20(asset()).forceApprove(address(morpho), 0);

        supplied = assetsSupplied;
        suppliedForMarket[tokenId] += supplied;
        suppliedForClass[key] = suppliedForClass[key] + supplied; // use actual supplied
        _totalSuppliedAssets += supplied;
        _trackMarket(tokenId);
        emit Supplied(tokenId, key, supplied);
    }

    function withdrawFor(uint256 tokenId, uint256 assets) external onlyRouter nonReentrant returns (uint256 withdrawn) {
        MarketParams memory params = registry.marketParamsOf(tokenId);
        Id id = params.id();
        uint256 shares = morpho.supplyShares(id, address(this));
        if (shares == 0) return 0;

        morpho.accrueInterest(params);
        if (assets == type(uint256).max) {
            (withdrawn,) = morpho.withdraw(params, 0, shares, address(this), address(this));
        } else {
            if (assets == 0) return 0;
            (withdrawn,) = morpho.withdraw(params, assets, 0, address(this), address(this));
        }
        emit WithdrawnFromMarket(tokenId, _classKey(tokenId), withdrawn);
    }

    function onRepay(uint256 tokenId, uint256 principal, uint256 interest) external onlyRouter nonReentrant {
        if (principal + interest == 0) return;
        bytes32 key = _classKey(tokenId);
        uint256 principalPaid = Math.min(principal, suppliedForMarket[tokenId]);
        suppliedForMarket[tokenId] -= principalPaid;
        suppliedForClass[key] -= Math.min(principalPaid, suppliedForClass[key]);
        _totalSuppliedAssets -= principalPaid;
        if (principalPaid > 0) emit PrincipalReturned(tokenId, principalPaid);

        uint256 remaining = (principal - principalPaid) + interest; // overpaid principal counts as interest
        if (remaining == 0) return;
        uint256 fee;
        if (reserveFactorBps != 0 && address(feeCollector) != address(0)) {
            fee = remaining * reserveFactorBps / 10_000;
            if (fee != 0) {
                IERC20(asset()).safeTransfer(address(feeCollector), fee);
                feeCollector.notify(FEE_RESERVE, asset(), fee, tokenId);
            }
        }
        // The rest stays in the vault as idle cash; totalAssets rises, share price rises.
        emit InterestAccrued(tokenId, remaining, fee);
    }

    function onLoss(uint256 tokenId, uint256 assets) external onlyRouter nonReentrant {
        if (assets == 0) return;
        uint256 recorded = suppliedForMarket[tokenId];
        if (assets > recorded) revert LossExceedsPosition(tokenId, assets, recorded);
        bytes32 key = _classKey(tokenId);
        suppliedForMarket[tokenId] = recorded - assets;
        suppliedForClass[key] -= Math.min(assets, suppliedForClass[key]);
        _totalSuppliedAssets -= assets;
        emit LossRealized(tokenId, key, assets);
    }

    // ------------------------------------------------------------------ accrual

    /// @dev Must be called before any share-price-affecting op. We iterate at most `accrueBatchSize` markets
    ///      per call for gas safety. The remainder can be swept by `sweep(start, count)` or by keeper A-6.
    function _accrueAll() internal {
        uint256 n = activeMarkets.length;
        uint256 limit = n < accrueBatchSize ? n : accrueBatchSize;
        for (uint256 i; i < limit; ++i) {
            uint256 tokenId = activeMarkets[i];
            MarketParams memory params = registry.marketParamsOf(tokenId);
            morpho.accrueInterest(params);
            // supply balance on Morpho may have grown; our stored principal is the economic claim.
            // Interest is credited only when it is actually paid back via onRepay, so no action here.
            // We purge finished markets opportunistically.
            if (morpho.supplyShares(params.id(), address(this)) == 0) {
                _untrackMarket(tokenId);
                if (i < activeMarkets.length) {
                    // activeMarkets shrank; recheck this index
                    --i;
                    --limit;
                    if (limit > activeMarkets.length) limit = activeMarkets.length;
                }
            }
        }
    }

    /// @notice Public batch accrual. Callable by anyone (keeper A-6). No-op per index without a position.
    function sweep(uint256 start, uint256 count) external {
        uint256 n = activeMarkets.length;
        if (start >= n) return;
        uint256 end = start + count;
        if (end > n) end = n;
        for (uint256 i = start; i < end; ++i) {
            morpho.accrueInterest(registry.marketParamsOf(activeMarkets[i]));
        }
    }

    // ------------------------------------------------------------------ ERC-4626 overrides

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + _totalSuppliedAssets;
    }

    function totalSuppliedAssets() external view returns (uint256) {
        return _totalSuppliedAssets;
    }

    /// @dev Withdrawals/redeems are capped by vault cash (what isn't currently out as loans).
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 own = convertToAssets(balanceOf(owner));
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        return own < cash ? own : cash;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 cashShares = convertToShares(cash);
        uint256 own = balanceOf(owner);
        return own < cashShares ? own : cashShares;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        _accrueAll();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal override {
        _accrueAll();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    // ------------------------------------------------------------------ internals

    /// @dev Used only by supplyFor: the lot must exist (not burned) and must have a Morpho market.
    function _paramsAndKey(uint256 tokenId) internal view returns (MarketParams memory params, bytes32 key) {
        if (!passport.exists(tokenId)) revert UnknownLot(tokenId);
        params = registry.marketParamsOf(tokenId);
        key = _classKey(tokenId);
    }

    function _classKey(uint256 tokenId) internal view returns (bytes32) {
        IMaterialPassport.Lot memory lot = passport.lotOf(tokenId);
        return keccak256(abi.encode(lot.materialCode, lot.warehouseId));
    }

    function _trackMarket(uint256 tokenId) internal {
        if (_activeIndexPlus1[tokenId] != 0) return;
        activeMarkets.push(tokenId);
        _activeIndexPlus1[tokenId] = activeMarkets.length;
    }

    function _untrackMarket(uint256 tokenId) internal {
        uint256 idxPlus1 = _activeIndexPlus1[tokenId];
        if (idxPlus1 == 0) return;
        uint256 idx = idxPlus1 - 1;
        uint256 last = activeMarkets.length - 1;
        if (idx != last) {
            uint256 moved = activeMarkets[last];
            activeMarkets[idx] = moved;
            _activeIndexPlus1[moved] = idx + 1;
        }
        activeMarkets.pop();
        delete _activeIndexPlus1[tokenId];
    }

    function activeMarketCount() external view returns (uint256) {
        return activeMarkets.length;
    }
}
