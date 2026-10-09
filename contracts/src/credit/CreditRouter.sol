// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMorpho, MarketParams, Id, Market} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoLib} from "morpho-blue/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "morpho-blue/libraries/SharesMathLib.sol";
import {TensileAccessControlled} from "../access/TensileAccessControlled.sol";
import {ITensileAccess} from "../interfaces/ITensileAccess.sol";
import {ICreditRouter} from "../interfaces/ICreditRouter.sol";
import {IMarketRegistry} from "../interfaces/IMarketRegistry.sol";
import {IMaterialPassport} from "../interfaces/IMaterialPassport.sol";
import {IPriceOracleAdapter} from "../interfaces/IPriceOracleAdapter.sol";
import {IReserveGuard} from "../interfaces/IReserveGuard.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {IFeeCollector} from "../interfaces/IFeeCollector.sol";
import {ILotWrapper} from "../interfaces/ILotWrapper.sol";
import {ITensileCreditVault} from "../interfaces/ITensileCreditVault.sol";

/// @title CreditRouter (C-15)
/// @notice Borrowing against lots using EXISTING Morpho Blue liquidity — Tensile runs no lending pool.
///
///         openLoan: lot NFT -> LotWrapper ERC-20 -> Morpho supplyCollateral -> Morpho borrow -> borrower.
///         The ROUTER is the Morpho position owner for every lot market (one lot = one isolated market = one
///         position), and records the economic borrower in `borrowerOf`. Users therefore never have to grant
///         Morpho authorisations, and nobody can bypass Tensile's checks to move the collateral.
///
///         Lenders supply USDC to the lot's Morpho market directly (or via a Morpho vault). Liquidations are
///         performed on Morpho by anyone (KYC-verified, because they receive the wrapper token).
contract CreditRouter is ICreditRouter, TensileAccessControlled, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    bytes32 public constant FEE_ORIGINATION = keccak256("ORIGINATION");
    uint16 public constant MAX_ORIGINATION_FEE_BPS = 300;

    IMorpho public immutable morpho;
    IMarketRegistry public immutable registry;
    IMaterialPassport public immutable passport;
    IPriceOracleAdapter public immutable adapter;
    IReserveGuard public immutable guard;
    IIdentityRegistry public immutable identity;
    IERC20 public immutable loanToken;

    IFeeCollector public feeCollector;
    uint16 public originationFeeBps = 100; // 1%
    address public marketplace;
    ITensileCreditVault public vault; // set once; when set, lender liquidity flows through the vault

    mapping(uint256 => address) public borrowerOf;

    event LoanOpened(uint256 indexed tokenId, address indexed borrower, uint256 borrowed, uint256 fee);
    event Borrowed(uint256 indexed tokenId, address indexed borrower, uint256 borrowed, uint256 fee);
    event Repaid(uint256 indexed tokenId, address indexed payer, uint256 assets);
    event LoanClosed(uint256 indexed tokenId, address indexed borrower, address indexed recipient, uint256 collateral, bool unwrapped);
    event PaidOffBySale(uint256 indexed tokenId, address indexed borrower, address indexed recipient, uint256 paid);
    event MarketplaceSet(address marketplace);
    event FeeConfigSet(address collector, uint16 bps);
    event VaultSet(address vault);

    error NotVerified(address account);
    error NotLotOwner();
    error NotBorrower();
    error NotMarketplace();
    error LoanExists(uint256 tokenId);
    error NoLoan(uint256 tokenId);
    error NoDebt(uint256 tokenId);
    error ZeroAmount();
    error LotNotFree(uint256 tokenId);
    error ClassDisabled();
    error StaleAttestation(uint256 tokenId);
    error WarehouseUnhealthy(uint32 warehouseId);
    error ExceedsMaxLtv(uint256 requested, uint256 maxBorrow);
    error PartiallyLiquidated(uint256 tokenId, uint256 collateral, uint256 fullSupply);
    error InvalidFee();
    error AlreadySet();
    error VaultNotSet();

    constructor(
        ITensileAccess access_,
        IMorpho morpho_,
        IMarketRegistry registry_,
        IMaterialPassport passport_,
        IPriceOracleAdapter adapter_,
        IReserveGuard guard_,
        IIdentityRegistry identity_,
        IERC20 loanToken_,
        IFeeCollector feeCollector_
    ) TensileAccessControlled(access_) {
        if (
            address(morpho_) == address(0) || address(registry_) == address(0) || address(passport_) == address(0)
                || address(adapter_) == address(0) || address(guard_) == address(0)
                || address(identity_) == address(0) || address(loanToken_) == address(0)
                || address(feeCollector_) == address(0)
        ) revert ZeroAddress();
        morpho = morpho_;
        registry = registry_;
        passport = passport_;
        adapter = adapter_;
        guard = guard_;
        identity = identity_;
        loanToken = loanToken_;
        feeCollector = feeCollector_;
    }

    // ------------------------------------------------------------------ admin

    /// @notice One-time wiring. Immutable afterwards: a compromised admin cannot swap in a fake marketplace
    ///         that could call `payoffFor` and take lots worth more than their debt.
    function setMarketplace(address marketplace_) external onlyAdmin {
        if (marketplace_ == address(0)) revert ZeroAddress();
        if (marketplace != address(0)) revert AlreadySet();
        marketplace = marketplace_;
        emit MarketplaceSet(marketplace_);
    }

    /// @notice Wire the credit vault once. When set, the router pulls liquidity from the vault on openLoan
    ///         / borrowMore and pushes repayments back to it on repay / closeLoan / payoffFor, and reports
    ///         any shortfall after a close via onLoss. Lenders deposit directly into the vault.
    function setVault(ITensileCreditVault vault_) external onlyAdmin {
        if (address(vault_) == address(0)) revert ZeroAddress();
        if (address(vault) != address(0)) revert AlreadySet();
        vault = vault_;
        emit VaultSet(address(vault_));
    }

    function setFeeConfig(IFeeCollector collector, uint16 bps) external onlyAdmin {
        if (address(collector) == address(0)) revert ZeroAddress();
        if (bps > MAX_ORIGINATION_FEE_BPS) revert InvalidFee();
        feeCollector = collector;
        originationFeeBps = bps;
        emit FeeConfigSet(address(collector), bps);
    }

    // ------------------------------------------------------------------ borrower actions

    /// @notice Pledge a lot and borrow in one transaction.
    /// @dev Caller must have approved this router for the lot NFT. The lot's Morpho market needs supply liquidity.
    function openLoan(uint256 tokenId, uint256 borrowAssets) external nonReentrant returns (uint256 net) {
        if (borrowAssets == 0) revert ZeroAmount();
        if (borrowerOf[tokenId] != address(0)) revert LoanExists(tokenId);
        if (!identity.isVerified(msg.sender)) revert NotVerified(msg.sender);
        if (passport.ownerOf(tokenId) != msg.sender) revert NotLotOwner();
        IMaterialPassport.Lot memory lot = passport.lotOf(tokenId);
        if (lot.state != IMaterialPassport.LotState.FREE) revert LotNotFree(tokenId);

        IMarketRegistry.ClassConfig memory cfg = _preBorrowChecks(tokenId, lot);
        uint256 maxBorrow = adapter.lotValue(tokenId) * cfg.routerMaxLtvBps / 10_000;
        if (borrowAssets > maxBorrow) revert ExceedsMaxLtv(borrowAssets, maxBorrow);

        MarketParams memory params = registry.ensureLotMarket(tokenId);
        borrowerOf[tokenId] = msg.sender;

        // lot NFT -> router -> wrapper; full wrapper supply minted to the router
        passport.transferFrom(msg.sender, address(this), tokenId);
        ILotWrapper wrapper = ILotWrapper(params.collateralToken);
        passport.approve(address(wrapper), tokenId);
        uint256 supply = wrapper.wrap(address(this));

        IERC20(address(wrapper)).forceApprove(address(morpho), supply);
        morpho.supplyCollateral(params, supply, address(this), "");
        _ensureLiquidity(tokenId, borrowAssets);
        morpho.borrow(params, borrowAssets, 0, address(this), address(this));

        net = _payOut(tokenId, borrowAssets);
        emit LoanOpened(tokenId, msg.sender, borrowAssets, borrowAssets - net);
    }

    /// @notice Borrow more against an existing loan, within the router LTV cap on the CURRENT collateral.
    function borrowMore(uint256 tokenId, uint256 borrowAssets) external nonReentrant returns (uint256 net) {
        if (borrowAssets == 0) revert ZeroAmount();
        if (borrowerOf[tokenId] != msg.sender) revert NotBorrower();
        if (!identity.isVerified(msg.sender)) revert NotVerified(msg.sender);
        IMaterialPassport.Lot memory lot = passport.lotOf(tokenId);

        IMarketRegistry.ClassConfig memory cfg = _preBorrowChecks(tokenId, lot);
        MarketParams memory params = registry.marketParamsOf(tokenId);
        uint256 collateral = morpho.collateral(params.id(), address(this));
        uint256 fullSupply = ILotWrapper(params.collateralToken).fullSupply();
        uint256 value = adapter.lotValue(tokenId) * collateral / fullSupply;
        uint256 maxBorrow = value * cfg.routerMaxLtvBps / 10_000;
        uint256 debt = morpho.expectedBorrowAssets(params, address(this));
        if (debt + borrowAssets > maxBorrow) revert ExceedsMaxLtv(debt + borrowAssets, maxBorrow);

        _ensureLiquidity(tokenId, borrowAssets);
        morpho.borrow(params, borrowAssets, 0, address(this), address(this));
        net = _payOut(tokenId, borrowAssets);
        emit Borrowed(tokenId, msg.sender, borrowAssets, borrowAssets - net);
    }

    /// @notice Repay part or all of a loan. Anyone may repay on behalf of the borrower.
    ///         If `assets` >= outstanding debt, exactly the outstanding debt is pulled.
    function repay(uint256 tokenId, uint256 assets) external nonReentrant returns (uint256 repaid) {
        if (assets == 0) revert ZeroAmount();
        if (borrowerOf[tokenId] == address(0)) revert NoLoan(tokenId);
        MarketParams memory params = registry.marketParamsOf(tokenId);
        Id id = params.id();
        uint256 shares = morpho.borrowShares(id, address(this));
        if (shares == 0) revert NoDebt(tokenId);

        uint256 owed = _owedAssets(params, id, shares);
        if (assets >= owed) {
            repaid = _repayAll(params, id, msg.sender);
        } else {
            // Partial: convert `assets` to shares (round down) so the vault's principal / interest split is exact.
            morpho.accrueInterest(params);
            Market memory m = morpho.market(id);
            uint256 payShares = assets.toSharesDown(m.totalBorrowAssets, m.totalBorrowShares);
            if (payShares == 0) revert ZeroAmount();
            (repaid,,) = _repayFromPayer(params, id, msg.sender, payShares);
        }
        emit Repaid(tokenId, msg.sender, repaid);
    }

    /// @notice Repay everything still owed (pulled from the borrower) and release the collateral.
    ///         Full collateral -> lot NFT back to `recipient`. Partially liquidated -> remaining wrapper tokens.
    function closeLoan(uint256 tokenId, address recipient) external nonReentrant {
        address borrower = borrowerOf[tokenId];
        if (borrower != msg.sender) revert NotBorrower();
        if (recipient == address(0)) revert ZeroAddress();
        MarketParams memory params = registry.marketParamsOf(tokenId);
        Id id = params.id();

        if (morpho.borrowShares(id, address(this)) != 0) {
            uint256 paid = _repayAll(params, id, msg.sender);
            emit Repaid(tokenId, msg.sender, paid);
        }
        _reportLossIfAny(params, id, tokenId);
        delete borrowerOf[tokenId];
        (uint256 collateral, bool unwrapped) = _release(params, id, recipient);
        emit LoanClosed(tokenId, borrower, recipient, collateral, unwrapped);
    }

    // ------------------------------------------------------------------ marketplace hook

    /// @notice Called by C-16 during a sale of an encumbered lot: repays the full debt using USDC pulled from the
    ///         marketplace and delivers the lot NFT straight to the buyer. Atomic with the sale.
    function payoffFor(uint256 tokenId, address recipient) external nonReentrant returns (uint256 paid) {
        if (msg.sender != marketplace) revert NotMarketplace();
        address borrower = borrowerOf[tokenId];
        if (borrower == address(0)) revert NoLoan(tokenId);
        MarketParams memory params = registry.marketParamsOf(tokenId);
        Id id = params.id();

        uint256 fullSupply = ILotWrapper(params.collateralToken).fullSupply();
        uint256 collateral = morpho.collateral(id, address(this));
        if (collateral != fullSupply) revert PartiallyLiquidated(tokenId, collateral, fullSupply);

        if (morpho.borrowShares(id, address(this)) != 0) paid = _repayAll(params, id, msg.sender);
        _reportLossIfAny(params, id, tokenId);
        delete borrowerOf[tokenId];
        _release(params, id, recipient);
        emit PaidOffBySale(tokenId, borrower, recipient, paid);
    }


    // ------------------------------------------------------------------ vault integration

    /// @dev Pull `assets` from the vault into Morpho's supply side for this lot's market.
    function _ensureLiquidity(uint256 tokenId, uint256 assets) internal {
        if (address(vault) == address(0)) revert VaultNotSet();
        vault.supplyFor(tokenId, assets);
    }

    /// @dev Pulls `assets` from `payer` directly into the vault (saves one transfer), then repays Morpho from
    ///      the vault's withdrawn balance. Returns (principalRepaid, interestEarnedByLenders).
    ///      The vault's internal accounting is updated by `onRepay`.
    function _repayFromPayer(MarketParams memory params, Id id, address payer, uint256 shares)
        internal
        returns (uint256 repaid, uint256 principal, uint256 interest)
    {
        uint256 owed = _owedAssets(params, id, shares);
        uint256 tokenId = IMarketRegistry(address(registry)).tokenIdOfWrapper(params.collateralToken);
        uint256 principalOutstanding = vault.suppliedForMarket(tokenId);

        // @note decide if all debt will be repaid
        bool withdrawAll = shares == morpho.borrowShares(id, address(this));


        // 1. repay Morpho by shares, with the payer funding this contract directly.
        //    Repaying BEFORE withdrawing the vault's supply makes the two sides net to zero in share terms,
        //    so withdrawFor sees a clean, fully-accrued balance to pull in step 2.
        loanToken.safeTransferFrom(payer, address(this), owed);
        loanToken.forceApprove(address(morpho), owed);
        (repaid,) = morpho.repay(params, 0, shares, address(this), "");
        loanToken.forceApprove(address(morpho), 0);
        // Any over-pull (shouldn't happen; defensive) is returned to the payer.
        if (owed > repaid) loanToken.safeTransfer(payer, owed - repaid);

        // 2. Withdraw the full market supply only when this call repaid all router debt.
        //    A partial repayment withdraws only the assets repaid.
        uint256 withdrawn = withdrawAll
            ? vault.withdrawFor(tokenId, type(uint256).max)
            : vault.withdrawFor(tokenId, repaid);

        // 3. tell the vault how to split what came back: at most principalOutstanding is principal,
        //    the rest (interest on the supply side) is lender interest. These should be close to `repaid`
        //    but Morpho shaves a tiny spread, so we use the ACTUAL amount delivered to the vault.
        principal = withdrawn > principalOutstanding ? principalOutstanding : withdrawn;
        interest = withdrawn - principal;
        vault.onRepay(tokenId, principal, interest);
    }

    /// @dev After a close, if Morpho shows the lot had unrecovered debt (collateral < fullSupply AND still
    ///      has borrowShares), socialise the loss on the vault.
    function _reportLossIfAny(MarketParams memory params, Id id, uint256 tokenId) internal {
        if (address(vault) == address(0)) return;
        uint256 principalOutstanding = vault.suppliedForMarket(tokenId);
        if (principalOutstanding == 0) return;
        // After we repaid by shares, our shares are 0 and _repayFromPayer dropped the principal accordingly.
        // Any remaining principal recorded here against this market was taken as Morpho bad debt.
        // (In the rare case the position still has borrowShares for another borrower-less reason, we leave it.)
        if (morpho.borrowShares(id, address(this)) == 0) {
            vault.onLoss(tokenId, principalOutstanding);
        }
    }

    // ------------------------------------------------------------------ views

    function debtOf(uint256 tokenId) external view returns (uint256) {
        if (borrowerOf[tokenId] == address(0)) return 0;
        return morpho.expectedBorrowAssets(registry.marketParamsOf(tokenId), address(this));
    }

    function collateralOf(uint256 tokenId) external view returns (uint256) {
        if (registry.wrapperOf(tokenId) == address(0)) return 0;
        MarketParams memory params = registry.marketParamsOf(tokenId);
        return morpho.collateral(params.id(), address(this));
    }

    /// @notice Max additional borrow allowed by the router cap right now (0 if none). Reverts if price stale.
    function availableToBorrow(uint256 tokenId) external view returns (uint256) {
        IMarketRegistry.ClassConfig memory cfg = registry.classOf(tokenId);
        uint256 value = adapter.lotValue(tokenId);
        if (borrowerOf[tokenId] == address(0)) return value * cfg.routerMaxLtvBps / 10_000;
        MarketParams memory params = registry.marketParamsOf(tokenId);
        uint256 collateral = morpho.collateral(params.id(), address(this));
        uint256 maxBorrow = value * collateral / ILotWrapper(params.collateralToken).fullSupply() * cfg.routerMaxLtvBps / 10_000;
        uint256 debt = morpho.expectedBorrowAssets(params, address(this));
        return maxBorrow > debt ? maxBorrow - debt : 0;
    }

    // ------------------------------------------------------------------ internals

    function _preBorrowChecks(uint256 tokenId, IMaterialPassport.Lot memory lot)
        internal
        view
        returns (IMarketRegistry.ClassConfig memory cfg)
    {
        cfg = registry.classOf(tokenId);
        if (!cfg.enabled) revert ClassDisabled();
        if (block.timestamp - lot.lastAttestedAt > cfg.maxAttestationAge) revert StaleAttestation(tokenId);
        if (!guard.isHealthy(lot.warehouseId)) revert WarehouseUnhealthy(lot.warehouseId);
        adapter.requireStablePeg();
    }

    function _payOut(uint256 tokenId, uint256 borrowAssets) internal returns (uint256 net) {
        uint256 fee = borrowAssets * originationFeeBps / 10_000;
        net = borrowAssets - fee;
        if (fee != 0) {
            loanToken.safeTransfer(address(feeCollector), fee);
            feeCollector.notify(FEE_ORIGINATION, address(loanToken), fee, tokenId);
        }
        loanToken.safeTransfer(msg.sender, net);
    }

    function _owedAssets(MarketParams memory params, Id id, uint256 shares) internal returns (uint256) {
        morpho.accrueInterest(params);
        Market memory m = morpho.market(id);
        return shares.toAssetsUp(m.totalBorrowAssets, m.totalBorrowShares);
    }

    /// @dev Pulls exactly the outstanding debt from `payer` and repays by shares. Routes through the vault
    ///      so lender principal and interest are accounted for.
    function _repayAll(MarketParams memory params, Id id, address payer) internal returns (uint256 repaid) {
        uint256 shares = morpho.borrowShares(id, address(this));
        if (shares == 0) return 0;
        (repaid,,) = _repayFromPayer(params, id, payer, shares);
    }

    /// @dev Withdraws ALL collateral of the router position in this market and hands it to `recipient`.
    function _release(MarketParams memory params, Id id, address recipient)
        internal
        returns (uint256 collateral, bool unwrapped)
    {
        collateral = morpho.collateral(id, address(this));
        if (collateral == 0) return (0, false);
        morpho.withdrawCollateral(params, collateral, address(this), address(this));
        ILotWrapper wrapper = ILotWrapper(params.collateralToken);
        if (collateral == wrapper.fullSupply()) {
            wrapper.unwrap(recipient);
            unwrapped = true;
        } else {
            IERC20(address(wrapper)).safeTransfer(recipient, collateral);
        }
    }
}
