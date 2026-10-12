// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {IMorpho, MarketParams} from "morpho-blue/interfaces/IMorpho.sol";
import {TensileDeployer} from "./TensileDeployer.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Roles} from "../src/access/Roles.sol";
import {ITensileAccess} from "../src/interfaces/ITensileAccess.sol";
import {IAttestationRegistry} from "../src/interfaces/IAttestationRegistry.sol";
import {IMaterialPassport} from "../src/interfaces/IMaterialPassport.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {IPriceOracleAdapter} from "../src/interfaces/IPriceOracleAdapter.sol";
import {IWarehouseRegistry} from "../src/interfaces/IWarehouseRegistry.sol";
import {ILotWrapper} from "../src/interfaces/ILotWrapper.sol";
import {TensileReserveFeed} from "../src/reserve/TensileReserveFeed.sol";
import {ITensileCreditVault} from "../src/interfaces/ITensileCreditVault.sol";
import {IMarketRegistry as _IMR} from "../src/interfaces/IMarketRegistry.sol";
import {TensilePriceFeed} from "../src/pricing/TensilePriceFeed.sol";
import {TensileMorphoOracle} from "../src/credit/TensileMorphoOracle.sol";
import {MintingController} from "../src/asset/MintingController.sol";

/// @notice LOCAL SIMULATION of flows F-0 … F-7 (no broadcast). Doubles as an end-to-end smoke check:
///         every `require` must hold and every "blocked as expected" call must revert.
///
///   forge script script/DemoFlow.s.sol -vv
contract DemoFlow is TensileDeployer {
    bytes32 constant MC = keccak256("REBAR-B500B-12MM");
    bytes32 constant REGION = "NG-LAGOS";
    uint256 constant LLTV = 0.77e18;

    address admin;
    address kycAdmin;
    address riskAdmin;
    address agent; // A-1 / A-5 key (AI_AGENT + PRICE_UPDATER) — separate keys in production
    address inspector;
    address operator;
    address okafor; // material owner
    address maria; // lender
    address buildco; // buyer
    address liquidator;
    uint256 whSignerKey;
    uint256 inspSignerKey;

    IMorpho morpho;
    MockUSDC usdc;
    TensileReserveFeed reserveFeed;
    TensilePriceFeed priceFeed;
    uint32 wid;

    function run() external {
        vm.warp(1_790_000_000);
        _actors();
        _deployAll();
        _onboard(); // F-0

        uint256 lot1 = _tokenize(500_000, "MTC-24-118"); // F-1
        _borrow(lot1, 195_000e6); // F-2
        _sellEncumbered(lot1, 305_000e6); // F-3
        _redeem(lot1); // F-5
        uint256 lot2 = _tokenize(300_000, "MTC-24-207");
        _liquidation(lot2); // F-7
        _reserveBreach(); // F-6
        _rfqAndDispute(lot2); // F-3b + F-5b

        console.log("");
        console.log("ALL FLOWS PASSED");
    }

    // ================================================================== setup

    function _actors() internal {
        admin = makeAddr("admin");
        kycAdmin = makeAddr("kycAdmin");
        riskAdmin = makeAddr("riskAdmin");
        agent = makeAddr("agent");
        inspector = makeAddr("inspector");
        operator = makeAddr("warehouseOperator");
        okafor = makeAddr("okaforSteel");
        maria = makeAddr("maria");
        buildco = makeAddr("buildco");
        liquidator = makeAddr("liquidator");
        (, whSignerKey) = makeAddrAndKey("warehouseSigner");
        (, inspSignerKey) = makeAddrAndKey("inspectorSigner");
    }

    function _deployAll() internal {
        vm.startPrank(admin);
        usdc = new MockUSDC();
        morpho = IMorpho(deployCode("out/Morpho.sol/Morpho.json", abi.encode(admin)));
        address irm = deployCode("out/AdaptiveCurveIrm.sol/AdaptiveCurveIrm.json", abi.encode(address(morpho)));
        morpho.enableIrm(irm);
        morpho.enableLltv(LLTV);
        _deployTensile(
            DeployConfig({
                morpho: address(morpho),
                irm: irm,
                usdc: address(usdc),
                usdcDecimals: 6,
                reserveMaxStaleness: 1 days,
                passportBaseURI: "https://tensile.app/lot/"
            }),
            admin
        );
        accessManager.grantRole(Roles.KYC_ADMIN, kycAdmin);
        accessManager.grantRole(Roles.RISK_ADMIN, riskAdmin);
        accessManager.grantRole(Roles.AI_AGENT, agent);
        accessManager.grantRole(Roles.PRICE_UPDATER, agent);
        accessManager.grantRole(Roles.INSPECTOR, inspector);
        vm.stopPrank();
        console.log("Deployed Tensile + Morpho Blue locally");
    }

    /// F-0 Onboarding
    function _onboard() internal {
        console.log("F-0 onboarding");
        ITensileAccess a = ITensileAccess(address(accessManager));

        vm.startPrank(admin);
        wid = warehouses.registerWarehouse(operator, REGION, "ipfs://warehouse-lagos-3");
        reserveFeed = new TensileReserveFeed(a, wid, "TENSILE-WH-1 RESERVE KG", vm.addr(whSignerKey), vm.addr(inspSignerKey));
        warehouses.setReserveFeed(wid, address(reserveFeed));
        priceFeed = new TensilePriceFeed(a, "REBAR-B500B-12MM / NG-LAGOS USD/t");
        vm.stopPrank();

        vm.prank(agent);
        priceFeed.update(600e8); // $600 / tonne

        TensileMorphoOracle oracle = new TensileMorphoOracle(
            IPriceOracleAdapter(address(adapter)), IWarehouseRegistry(address(warehouses)), MC, wid
        );
        vm.startPrank(riskAdmin);
        adapter.setFeed(MC, REGION, address(priceFeed));
        bytes32 classKey = keccak256(abi.encode(MC, wid));
        vault.setClassCap(classKey, 500_000e6); // 500k USDC cap for this (material, warehouse)
        vault.setFeeConfig(fees, 1_000); // 10% reserve factor on interest earned
        registry.setClass(
            MC,
            wid,
            IMarketRegistry.ClassConfig({
                oracle: address(oracle),
                lltv: LLTV,
                routerMaxLtvBps: 6_500,
                maxAttestationAge: 30 days,
                enabled: true
            })
        );
        vm.stopPrank();

        uint64 exp = uint64(block.timestamp + 365 days);
        vm.startPrank(kycAdmin);
        identity.setIdentity(okafor, "NG", 2, exp);
        identity.setIdentity(maria, "GB", 1, exp);
        identity.setIdentity(buildco, "NG", 2, exp);
        identity.setIdentity(liquidator, "AE", 3, exp);
        vm.stopPrank();

        usdc.faucet(maria, 1_000_000e6);
        usdc.faucet(buildco, 1_000_000e6);
        usdc.faucet(okafor, 500_000e6);
        usdc.faucet(liquidator, 1_000_000e6);
    }

    // ================================================================== flows

    /// F-1 Tokenize a lot: request -> AI review -> inspection -> custody -> reserve -> finalize
    function _tokenize(uint96 qtyKg, string memory certName) internal returns (uint256 tokenId) {
        console.log("F-1 tokenize lot, kg:", qtyKg);
        bytes32 certHash = keccak256(bytes(certName));

        vm.prank(okafor);
        uint256 reqId = controller.requestMint(wid, MC, qtyKg, certHash, "ipfs://evidence");

        // duplicate certificate is rejected while the first request is open
        _mustFail(okafor, address(controller), abi.encodeCall(controller.requestMint, (wid, MC, qtyKg, certHash, "x")), "duplicate certificate");

        vm.prank(agent);
        attestations.attest(IAttestationRegistry.Kind.AI_REVIEW, IAttestationRegistry.SubjectType.REQUEST, reqId, 92, keccak256("ai-report"), "ipfs://ai");
        vm.prank(inspector);
        attestations.attest(IAttestationRegistry.Kind.INSPECTION, IAttestationRegistry.SubjectType.REQUEST, reqId, 0, keccak256("inspection"), "ipfs://insp");

        // cannot finalize before custody
        _mustFail(okafor, address(controller), abi.encodeCall(controller.finalizeMint, (reqId)), "finalize without custody");

        vm.prank(operator);
        controller.confirmCustody(reqId, keccak256("custody"), "ipfs://custody");

        // cannot finalize while reserves don't cover outstanding + new quantity
        _mustFail(okafor, address(controller), abi.encodeCall(controller.finalizeMint, (reqId)), "finalize without reserve coverage");

        _submitReserve(passport.outstandingKg(wid) + qtyKg);
        tokenId = controller.finalizeMint(reqId);
        require(passport.ownerOf(tokenId) == okafor, "owner");
        console.log("  minted token", tokenId);
    }

    /// F-2 Lend (Maria on Morpho) & borrow (Okafor through the router)
    function _borrow(uint256 tokenId, uint256 amount) internal {
        console.log("F-2 lend into vault & borrow via router, USDC:", amount / 1e6);
        MarketParams memory p = registry.ensureLotMarket(tokenId);

        // Maria deposits once into the vault; her USDC is available for ANY lot inside its class cap.
        vm.startPrank(maria);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(250_000e6, maria);
        require(shares > 0, "shares minted");
        // Withdraw-capped-by-cash: before any borrow, Maria can withdraw everything
        require(vault.maxWithdraw(maria) == 250_000e6, "pre-borrow maxWithdraw");
        vm.stopPrank();

        // Class cap: a request above the configured cap must fail cleanly on the router open.
        _mustFail(okafor, address(router), abi.encodeCall(router.openLoan, (tokenId, 500_001e6)), "openLoan above class cap");

        // above the 65% router cap ($300k * 65% = $195k) is refused
        vm.prank(okafor);
        passport.approve(address(router), tokenId);
        _mustFail(okafor, address(router), abi.encodeCall(router.openLoan, (tokenId, amount + 1e6)), "borrow above router LTV");

        uint256 before = usdc.balanceOf(okafor);
        vm.prank(okafor);
        router.openLoan(tokenId, amount);
        uint256 received = usdc.balanceOf(okafor) - before;
        require(vault.suppliedForMarket(tokenId) == amount, "vault supplied == borrowed");
        require(usdc.balanceOf(address(vault)) == 250_000e6 - amount, "vault cash reduced");
        require(vault.maxWithdraw(maria) == 250_000e6 - amount, "withdraw capped by cash");
        _mustFail(maria, address(vault), abi.encodeWithSignature("withdraw(uint256,address,address)", 250_000e6, maria, maria), "withdraw more than cash");
        require(received == amount - amount / 100, "net of 1% fee");
        require(passport.ownerOf(tokenId) == registry.wrapperOf(tokenId), "lot held by wrapper");
        require(router.borrowerOf(tokenId) == okafor, "borrower recorded");

        // the pledged lot can't be sold or pledged twice
        _mustFail(okafor, address(passport), abi.encodeWithSignature("transferFrom(address,address,uint256)", okafor, buildco, tokenId), "transfer pledged lot");
        _mustFail(okafor, address(router), abi.encodeCall(router.openLoan, (tokenId, 1e6)), "second loan on same lot");
        console.log("  borrowed, net USDC:", received / 1e6);
    }

    /// F-3 Sell an encumbered lot: payment + loan payoff + title transfer in one tx
    function _sellEncumbered(uint256 tokenId, uint128 price) internal {
        vm.warp(block.timestamp + 30 days);
        _submitReserve(passport.outstandingKg(wid));
        vm.prank(agent);
        priceFeed.update(610e8); // keep price fresh

        uint256 debt = router.debtOf(tokenId);
        console.log("F-3 sell encumbered lot, debt after 30d:", debt);

        vm.prank(okafor);
        uint256 listingId = marketplace.list(tokenId, price, address(0), uint64(block.timestamp + 7 days));

        uint256 sellerBefore = usdc.balanceOf(okafor);
        vm.startPrank(buildco);
        usdc.approve(address(marketplace), price);
        marketplace.buy(listingId);
        vm.stopPrank();

        require(passport.ownerOf(tokenId) == buildco, "buyer owns lot");
        require(router.borrowerOf(tokenId) == address(0), "loan closed");
        require(router.debtOf(tokenId) == 0, "no debt");
        require(vault.suppliedForMarket(tokenId) == 0, "vault position closed");
        // Vault cash is: starting deposit + interest kept after fee. Should exceed starting deposit (we earned yield).
        require(usdc.balanceOf(address(vault)) > 250_000e6, "vault earned interest");
        require(usdc.balanceOf(address(fees)) > 0, "reserve factor fee collected");
        uint256 proceeds = usdc.balanceOf(okafor) - sellerBefore;
        uint256 fee = uint256(price) * 25 / 10_000;
        require(proceeds + fee >= uint256(price) - debt - 1 && proceeds + fee <= uint256(price) - debt + 1, "proceeds");
        console.log("  seller proceeds USDC:", proceeds / 1e6);

        (uint256 last,,,,,) = _indexStats();
        require(last == 610e8, "index price per tonne");
    }

    /// F-5 Redemption: request -> warehouse release -> burn
    function _redeem(uint256 tokenId) internal {
        console.log("F-5 redeem lot", tokenId);
        uint256 outBefore = passport.outstandingKg(wid);
        vm.prank(buildco);
        redemption.requestRedemption(tokenId, keccak256("driver-secret-42"));
        _mustFail(buildco, address(passport), abi.encodeWithSignature("transferFrom(address,address,uint256)", buildco, okafor, tokenId), "transfer while redeeming");
        _mustFail(buildco, address(redemption), abi.encodeCall(redemption.confirmRelease, (tokenId, bytes32("x"), "")), "non-operator release");

        vm.prank(operator);
        redemption.confirmRelease(tokenId, keccak256("gate-pass+weighbridge"), "ipfs://release");
        require(!passport.exists(tokenId), "burned");
        require(passport.outstandingKg(wid) == outBefore - 500_000, "outstanding reduced");
        _submitReserve(passport.outstandingKg(wid)); // A-3 reconciles
        console.log("  burned; outstanding kg:", passport.outstandingKg(wid));
    }

    /// F-7 Default & liquidation on Morpho, then the borrower closes what is left
    function _liquidation(uint256 tokenId) internal {
        console.log("F-7 liquidation on Morpho");
        MarketParams memory p = registry.ensureLotMarket(tokenId);
        // Maria tops up the vault; no need to touch Morpho directly
        vm.prank(maria);
        vault.deposit(150_000e6, maria);

        // 300 t * $610 = $183k ; 65% = $118.95k
        vm.prank(okafor);
        passport.approve(address(router), tokenId);
        vm.prank(okafor);
        router.openLoan(tokenId, 118_000e6);

        // market shock: price falls 28% -> RISK_ADMIN force update (bypasses the 10% deviation bound)
        vm.warp(block.timestamp + 11 minutes);
        _submitReserve(passport.outstandingKg(wid));
        _mustFail(agent, address(priceFeed), abi.encodeCall(priceFeed.update, (int256(440e8))), "agent price move > 10%");
        vm.prank(riskAdmin);
        priceFeed.forceUpdate(440e8);

        ILotWrapper w = ILotWrapper(p.collateralToken);
        uint256 seize = w.fullSupply() / 2;

        // a non-KYC liquidator cannot receive the collateral
        address anon = makeAddr("anon");
        usdc.faucet(anon, 1_000_000e6);
        vm.prank(anon);
        usdc.approve(address(morpho), type(uint256).max);
        _mustFail(anon, address(morpho), abi.encodeCall(morpho.liquidate, (p, address(router), seize, 0, "")), "non-KYC liquidator");

        vm.startPrank(liquidator);
        usdc.approve(address(morpho), type(uint256).max);
        morpho.liquidate(p, address(router), seize, 0, "");
        vm.stopPrank();
        require(w.balanceOf(liquidator) == seize, "liquidator got half the lot");
        vm.prank(liquidator);
        w.approve(address(morpho), seize); // approval given, so only Tensile's rule can stop it
        _mustFail(liquidator, address(morpho), abi.encodeCall(morpho.supplyCollateral, (p, seize, liquidator, "")), "bypass router: deposit seized collateral on Morpho");
        _mustFail(liquidator, address(w), abi.encodeCall(w.transfer, (address(morpho), seize)), "bypass router: direct transfer to Morpho");
        console.log("  liquidator seized kg:", seize / 1e18);

        // partially liquidated lots cannot be sold via payoff (title is split)
        vm.prank(okafor);
        uint256 listingId = marketplace.list(tokenId, 200_000e6, address(0), uint64(block.timestamp + 1 days));
        vm.prank(buildco);
        usdc.approve(address(marketplace), 200_000e6);
        _mustFail(buildco, address(marketplace), abi.encodeCall(marketplace.buy, (listingId)), "buy partially liquidated lot");

        // borrower repays the rest and gets the remaining wrapper tokens back
        vm.startPrank(okafor);
        usdc.approve(address(router), type(uint256).max);
        router.closeLoan(tokenId, okafor);
        vm.stopPrank();
        require(w.balanceOf(okafor) == w.fullSupply() - seize, "residual collateral returned");
        require(router.borrowerOf(tokenId) == address(0), "closed");

        // whoever gathers 100% of the supply can unwrap the physical lot
        vm.prank(liquidator);
        w.transfer(okafor, seize);
        vm.prank(okafor);
        w.unwrap(okafor);
        require(passport.ownerOf(tokenId) == okafor, "re-assembled and unwrapped");
        console.log("  supply re-assembled and unwrapped by owner");

        vm.prank(riskAdmin);
        priceFeed.forceUpdate(610e8);
    }

    /// F-6 Reserve breach -> freeze -> blocked actions -> reconcile -> unfreeze
    function _reserveBreach() internal {
        console.log("F-6 reserve breach");
        uint256 outstanding = passport.outstandingKg(wid); // lot 2 (300 t) is live
        _submitReserve(outstanding - 50_000); // 50 t missing
        require(!guard.isHealthy(wid), "unhealthy");
        guard.poke(wid);
        require(warehouses.isFrozen(wid), "frozen");

        _mustFail(okafor, address(passport), abi.encodeWithSignature("transferFrom(address,address,uint256)", okafor, buildco, 2), "transfer at frozen warehouse");
        vm.prank(okafor);
        passport.approve(address(router), 2);
        _mustFail(okafor, address(router), abi.encodeCall(router.openLoan, (2, 1e6)), "borrow at frozen warehouse");
        _mustFail(okafor, address(controller), abi.encodeCall(controller.requestMint, (wid, MC, 1, keccak256("new"), "")), "mint at frozen warehouse");

        _submitReserve(outstanding); // stock found / reconciled
        vm.prank(admin);
        warehouses.unfreeze(wid);
        require(guard.isHealthy(wid) && !warehouses.isFrozen(wid), "recovered");
        console.log("  frozen, blocked, reconciled, unfrozen");
    }

    /// F-3b RFQ bid on a plain lot, then F-5b redemption dispute (warehouse misses the SLA)
    function _rfqAndDispute(uint256 tokenId) internal {
        console.log("F-3b RFQ bid on plain lot");
        vm.warp(block.timestamp + 11 minutes);
        _submitReserve(passport.outstandingKg(wid));
        vm.prank(agent);
        priceFeed.update(615e8);
        _mustFail(agent, address(priceFeed), abi.encodeCall(priceFeed.update, (int256(620e8))), "second agent update inside min interval");

        // a cancelled bid refunds the escrow
        vm.startPrank(buildco);
        usdc.approve(address(marketplace), type(uint256).max);
        uint256 b0 = usdc.balanceOf(buildco);
        uint256 cancelled = marketplace.placeBid(tokenId, 100_000e6, uint64(block.timestamp + 1 days));
        marketplace.cancelBid(cancelled);
        require(usdc.balanceOf(buildco) == b0, "refund");
        uint256 bidId = marketplace.placeBid(tokenId, 180_000e6, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        _mustFail(okafor, address(marketplace), abi.encodeCall(marketplace.acceptBid, (bidId)), "accept bid without NFT approval");
        vm.startPrank(okafor);
        passport.approve(address(marketplace), tokenId);
        marketplace.acceptBid(bidId);
        vm.stopPrank();
        require(passport.ownerOf(tokenId) == buildco, "bid settled");
        _mustFail(okafor, address(marketplace), abi.encodeCall(marketplace.acceptBid, (bidId)), "accept same bid twice");

        console.log("F-5b redemption dispute");
        vm.prank(buildco);
        redemption.requestRedemption(tokenId, keccak256("secret-2"));
        _mustFail(buildco, address(redemption), abi.encodeCall(redemption.raiseDispute, (tokenId)), "dispute before SLA");
        vm.warp(block.timestamp + 73 hours);
        vm.prank(buildco);
        redemption.raiseDispute(tokenId);
        require(!warehouses.isFrozen(wid), "dispute is a flag, not an auto-freeze");
        vm.prank(admin);
        warehouses.freeze(wid, "OPS_REVIEW"); // ops decides to freeze
        require(!guard.isHealthy(wid), "frozen => unhealthy even with good reserves");

        // the operator can still release to the rightful holder while frozen
        vm.prank(operator);
        redemption.confirmRelease(tokenId, keccak256("late-release"), "ipfs://late");
        require(!passport.exists(tokenId) && passport.outstandingKg(wid) == 0, "burned after dispute");
        vm.prank(admin);
        warehouses.unfreeze(wid);
        console.log("  dispute -> freeze -> late release -> unfreeze");
    }

    // ================================================================== helpers

    function _submitReserve(uint256 kg) internal {
        vm.warp(block.timestamp + 1);
        uint64 observedAt = uint64(block.timestamp);
        bytes32 digest = reserveFeed.reportDigest(int256(kg), observedAt);
        reserveFeed.submit(int256(kg), observedAt, _sign(whSignerKey, digest), _sign(inspSignerKey, digest));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mustFail(address who, address target, bytes memory data, string memory label) internal {
        vm.prank(who);
        (bool ok,) = target.call(data);
        require(!ok, string.concat("SHOULD HAVE REVERTED: ", label));
        console.log("  [blocked as expected]", label);
    }

    function _indexStats() internal view returns (uint256, uint256, uint64, uint64, uint256, uint256) {
        (bool ok, bytes memory ret) = address(index).staticcall(abi.encodeWithSignature("statsOf(bytes32,bytes32)", MC, REGION));
        require(ok, "index");
        return abi.decode(ret, (uint256, uint256, uint64, uint64, uint256, uint256));
    }
}
