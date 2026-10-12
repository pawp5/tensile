// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DemoFlow} from "../script/DemoFlow.s.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Roles} from "../src/access/Roles.sol";
import {CreditRouter} from "../src/credit/CreditRouter.sol";
import {ILotWrapper} from "../src/interfaces/ILotWrapper.sol";
import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {MarketParamsLib} from "morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoLib} from "morpho-blue/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "morpho-blue/libraries/periphery/MorphoBalancesLib.sol";

contract CreditRouterIssuesTest is DemoFlow, Test {
    using MarketParamsLib for MarketParams;
    using MorphoLib for IMorpho;
    using MorphoBalancesLib for IMorpho;
    uint256 lot1;

    function setUp() public {
        vm.warp(1_790_000_000);
        _actors();
        _deployAll();
        _onboard();

        // Tokenize a 500 tonne lot
        lot1 = _tokenize(500_000, "MTC-TEST-001");

        // Lender Maria deposits 250k USDC into the vault
        vm.startPrank(maria);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(250_000e6, maria);
        vm.stopPrank();

        // Borrower Okafor opens a loan for 100k USDC
        vm.startPrank(okafor);
        passport.approve(address(router), lot1);
        router.openLoan(lot1, 100_000e6);
        vm.stopPrank();
    }

    /// @notice Partial repayments withdraw only the amount repaid and leave the remaining loan active.
    function test_PartialRepayment_SucceedsAndLeavesDebt() public {
        uint256 debt = router.debtOf(lot1);
        assertGt(debt, 0, "Debt should be non-zero");

        uint256 partialRepayAmount = 10_000e6;
        assertLt(partialRepayAmount, debt, "Should be partial repayment");

        vm.startPrank(okafor);
        usdc.approve(address(router), type(uint256).max);
        uint256 repaid = router.repay(lot1, partialRepayAmount);
        vm.stopPrank();

        assertGt(repaid, 0, "Some debt shares should be repaid");
        assertLt(router.debtOf(lot1), debt, "Debt should decrease");
        assertGt(vault.suppliedForMarket(lot1), 0, "Market principal should remain tracked");
    }

    /// @notice Demonstrates that full repayment succeeds where partial repayment fails.
    function test_FullRepayment_Succeeds() public {
        uint256 debt = router.debtOf(lot1);

        vm.startPrank(okafor);
        usdc.approve(address(router), type(uint256).max);
        uint256 repaid = router.repay(lot1, debt);
        vm.stopPrank();

        assertGe(repaid, debt - 1, "Full debt was repaid");
        assertEq(router.debtOf(lot1), 0, "Remaining debt is 0");
    }

    /// @notice Morpho writes off exhausted collateral, but only a borrower-triggered close reports it to the vault.
    function test_BadDebt_RequiresBorrowerToCloseAndReportLoss() public {
        MarketParams memory p = registry.marketParamsOf(lot1);

        // Shock the price down to make position liquidatable
        vm.warp(block.timestamp + 11 minutes);
        _submitReserve(passport.outstandingKg(wid));
        vm.prank(riskAdmin);
        priceFeed.forceUpdate(100e8); // huge price drop

        // Liquidator liquidates all possible collateral
        uint256 fullCollateral = morpho.collateral(p.id(), address(router));

        vm.startPrank(liquidator);
        usdc.approve(address(morpho), type(uint256).max);
        morpho.liquidate(p, address(router), fullCollateral, 0, "");
        vm.stopPrank();

        // Morpho clears the borrow shares when collateral reaches zero, realizing bad debt in the market.
        assertEq(morpho.collateral(p.id(), address(router)), 0, "Collateral should be exhausted");
        assertEq(morpho.borrowShares(p.id(), address(router)), 0, "Morpho should clear bad-debt shares");
        uint256 trackedPrincipal = vault.suppliedForMarket(lot1);
        assertGt(trackedPrincipal, 0, "Vault has not been notified yet");

        // A keeper/admin cannot trigger the close that reports the loss.
        vm.prank(admin);
        vm.expectRevert(CreditRouter.NotBorrower.selector);
        router.closeLoan(lot1, admin);

        // Borrower close now needs no repayment because Morpho cleared the debt; it reports the loss.
        vm.startPrank(okafor);
        usdc.approve(address(router), type(uint256).max);
        router.closeLoan(lot1, okafor);
        vm.stopPrank();

        assertEq(vault.suppliedForMarket(lot1), 0, "Loss should be removed from tracked principal");
        assertEq(router.borrowerOf(lot1), address(0), "Loan record should be cleared");
        assertLt(vault.totalAssets(), trackedPrincipal + usdc.balanceOf(address(vault)), "Loss should reduce assets");
    }

    /// @notice Test 3: Demonstrates that when a warehouse is frozen, closeLoan reverts,
    /// preventing borrower from recovering their collateral NFT.
    function test_WarehouseFreeze_BlocksCollateralRecoveryOnClose() public {
        // Warehouse suffers a freeze (e.g. dispute / reserve issue)
        vm.prank(admin);
        warehouses.freeze(wid, "AUDIT_FREEZE");

        // Borrower attempts to repay and close their loan
        vm.startPrank(okafor);
        usdc.approve(address(router), type(uint256).max);

        // closeLoan will revert because _release calls passport.transferFrom, which reverts on frozen warehouse
        vm.expectRevert();
        router.closeLoan(lot1, okafor);
        vm.stopPrank();

    }

    /// @notice After partial liquidation, closing returns remaining wrapper tokens; the NFT stays wrapped.
    function test_PartialLiquidation_CloseReturnsWrapperTokens() public {
        MarketParams memory p = registry.marketParamsOf(lot1);
        vm.warp(block.timestamp + 11 minutes);
        _submitReserve(passport.outstandingKg(wid));
        vm.prank(riskAdmin);
        priceFeed.forceUpdate(100e8);

        uint256 fullCollateral = morpho.collateral(p.id(), address(router));
        uint256 seized = fullCollateral / 4;
        vm.startPrank(liquidator);
        usdc.approve(address(morpho), type(uint256).max);
        morpho.liquidate(p, address(router), seized, 0, "");
        vm.stopPrank();

        uint256 remainingCollateral = morpho.collateral(p.id(), address(router));
        assertGt(remainingCollateral, 0, "Some collateral should remain");
        assertLt(remainingCollateral, fullCollateral, "Liquidation should be partial");

        vm.startPrank(okafor);
        usdc.approve(address(router), type(uint256).max);
        router.closeLoan(lot1, okafor);
        vm.stopPrank();

        address wrapper = registry.wrapperOf(lot1);
        assertEq(ILotWrapper(wrapper).balanceOf(okafor), remainingCollateral, "Remaining collateral is returned");
        assertEq(passport.ownerOf(lot1), wrapper, "NFT remains inside wrapper after partial liquidation");
        assertEq(router.borrowerOf(lot1), address(0), "Loan record should be cleared");
    }

    /// @notice An unverified close recipient causes an atomic revert; repayment and debt state must remain unchanged.
    function test_CloseLoan_UnverifiedRecipientRevertsAtomically() public {
        address unverified = makeAddr("unverifiedRecipient");
        uint256 borrowerBalance = usdc.balanceOf(okafor);
        uint256 debtBefore = router.debtOf(lot1);

        vm.startPrank(okafor);
        usdc.approve(address(router), type(uint256).max);
        vm.expectRevert();
        router.closeLoan(lot1, unverified);
        vm.stopPrank();

        assertEq(usdc.balanceOf(okafor), borrowerBalance, "Repayment transfer must roll back");
        assertEq(router.debtOf(lot1), debtBefore, "Debt must remain unchanged");
        assertEq(router.borrowerOf(lot1), okafor, "Loan must remain open");
    }
}
