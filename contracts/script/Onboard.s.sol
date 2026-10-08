// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ITensileAccess} from "../src/interfaces/ITensileAccess.sol";
import {IPriceOracleAdapter} from "../src/interfaces/IPriceOracleAdapter.sol";
import {IWarehouseRegistry} from "../src/interfaces/IWarehouseRegistry.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {TensileAccessManager} from "../src/access/TensileAccessManager.sol";
import {WarehouseRegistry} from "../src/asset/WarehouseRegistry.sol";
import {PriceOracleAdapter} from "../src/pricing/PriceOracleAdapter.sol";
import {MarketRegistry} from "../src/credit/MarketRegistry.sol";
import {TensileReserveFeed} from "../src/reserve/TensileReserveFeed.sol";
import {TensilePriceFeed} from "../src/pricing/TensilePriceFeed.sol";
import {TensileMorphoOracle} from "../src/credit/TensileMorphoOracle.sol";
import {Roles} from "../src/access/Roles.sol";

/// @notice Onboards ONE warehouse and ONE material class on an existing deployment:
///         registers the warehouse, deploys its reserve feed (C-09), deploys a price feed (C-11a) for
///         (material, region), wires the adapter, deploys the Morpho oracle (C-13) and enables the class (C-12).
///
/// Env: PRIVATE_KEY (must hold ADMIN), OPERATOR, REGION (e.g. "NG-LAGOS"), WH_SIGNER, INSP_SIGNER,
///      MATERIAL (e.g. "REBAR-B500B-12MM"), INITIAL_PRICE (USD/t, 8 decimals),
///      LLTV (default 0.77e18), ROUTER_LTV_BPS (default 6500), MAX_ATTESTATION_AGE (default 30 days),
///      PRICE_UPDATER (agent A-5 address, optional)
/// Reads addresses from deployments/<chainId>.json written by Deploy.s.sol.
contract Onboard is Script {
    function run() external {
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        TensileAccessManager am = TensileAccessManager(vm.parseJsonAddress(json, ".C01_TensileAccessManager"));
        WarehouseRegistry warehouses = WarehouseRegistry(vm.parseJsonAddress(json, ".C03_WarehouseRegistry"));
        PriceOracleAdapter adapter = PriceOracleAdapter(vm.parseJsonAddress(json, ".C11_PriceOracleAdapter"));
        MarketRegistry registry = MarketRegistry(vm.parseJsonAddress(json, ".C12_MarketRegistry"));

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        string memory regionStr = vm.envString("REGION");
        string memory material = vm.envString("MATERIAL");
        bytes32 region = _toBytes32(regionStr);
        bytes32 mc = keccak256(bytes(material));

        vm.startBroadcast(pk);
        if (!am.hasRole(Roles.RISK_ADMIN, me)) am.grantRole(Roles.RISK_ADMIN, me);

        uint32 wid = warehouses.registerWarehouse(vm.envAddress("OPERATOR"), region, vm.envOr("WAREHOUSE_URI", string("")));
        TensileReserveFeed reserveFeed = new TensileReserveFeed(
            ITensileAccess(address(am)),
            wid,
            string.concat("TENSILE-WH-", vm.toString(uint256(wid)), " RESERVE KG"),
            vm.envAddress("WH_SIGNER"),
            vm.envAddress("INSP_SIGNER")
        );
        warehouses.setReserveFeed(wid, address(reserveFeed));

        TensilePriceFeed priceFeed =
            new TensilePriceFeed(ITensileAccess(address(am)), string.concat(material, " / ", regionStr, " USD/t"));
        priceFeed.forceUpdate(int256(vm.envUint("INITIAL_PRICE")));
        adapter.setFeed(mc, region, address(priceFeed));

        address updater = vm.envOr("PRICE_UPDATER", address(0));
        if (updater != address(0) && !am.hasRole(Roles.PRICE_UPDATER, updater)) am.grantRole(Roles.PRICE_UPDATER, updater);

        TensileMorphoOracle oracle = new TensileMorphoOracle(
            IPriceOracleAdapter(address(adapter)), IWarehouseRegistry(address(warehouses)), mc, wid
        );
        registry.setClass(
            mc,
            wid,
            IMarketRegistry.ClassConfig({
                oracle: address(oracle),
                lltv: vm.envOr("LLTV", uint256(0.77e18)),
                routerMaxLtvBps: uint16(vm.envOr("ROUTER_LTV_BPS", uint256(6_500))),
                maxAttestationAge: uint32(vm.envOr("MAX_ATTESTATION_AGE", uint256(30 days))),
                enabled: true
            })
        );
        vm.stopBroadcast();

        console.log("warehouseId", wid);
        console.log("materialCode");
        console.logBytes32(mc);
        console.log("reserveFeed", address(reserveFeed));
        console.log("priceFeed", address(priceFeed));
        console.log("morphoOracle", address(oracle));
    }

    function _toBytes32(string memory s) internal pure returns (bytes32 r) {
        bytes memory b = bytes(s);
        require(b.length > 0 && b.length <= 32, "REGION must be 1-32 bytes");
        assembly {
            r := mload(add(b, 32))
        }
    }
}
