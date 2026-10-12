// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TensileDeployer} from "./TensileDeployer.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Roles} from "../src/access/Roles.sol";

/// @notice Deploys the full Tensile protocol.
///
/// Env:
///   PRIVATE_KEY   deployer key (required)
///   ADMIN         final admin (Safe). Defaults to deployer. Deployer keeps ADMIN until you run the handover.
///   USDC          loan token address. Required unless DEPLOY_MOCK_USDC=true on a known dev/test chain.
///   MORPHO, IRM   deployed Morpho Blue + IRM addresses. Required unless DEPLOY_LOCAL_MORPHO=true.
///   LLTV          LLTV to enable on a self-deployed Morpho (default 0.77e18).
///   EXPECTED_CHAIN_ID expected network ID (required; protects against an RPC mismatch).
///   DEPLOY_MOCK_USDC / DEPLOY_LOCAL_MORPHO explicit dev/test deployment switches.
///   STABLE_FEED, STABLE_FLOOR, STABLE_MAX_STALENESS stablecoin/USD circuit breaker configuration.
///   BASE_URI      passport metadata base URI (Lot Explorer), default "https://tensile.app/lot/".
///   RESERVE_MAX_STALENESS seconds (default 86400).
///
/// Run:
///   forge script script/Deploy.s.sol --rpc-url monad_testnet --broadcast
contract Deploy is TensileDeployer {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        require(deployer != address(0), "invalid PRIVATE_KEY");
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        require(block.chainid == expectedChainId, "wrong chain id");
        address admin = vm.envOr("ADMIN", deployer);
        require(admin != address(0), "ADMIN is zero");
        string memory baseURI = vm.envOr("BASE_URI", string("https://tensile.app/lot/"));
        uint256 staleness = vm.envOr("RESERVE_MAX_STALENESS", uint256(1 days));
        require(staleness != 0, "RESERVE_MAX_STALENESS is zero");

        vm.startBroadcast(pk);
        (address usdc, uint8 decimals) = _resolveLoanToken();
        (address morpho, address irm) = _resolveMorpho(deployer, admin);

        DeployConfig memory config;
        config.morpho = morpho;
        config.irm = irm;
        config.usdc = usdc;
        config.usdcDecimals = decimals;
        config.reserveMaxStaleness = staleness;
        config.passportBaseURI = baseURI;
        _deployTensile(config, deployer);

        _configureStableGuard();

        if (admin != deployer) {
            accessManager.grantRole(Roles.ADMIN, admin);
            console.log("ADMIN granted to", admin, "- deployer retains ADMIN until handover");
        }

        vm.stopBroadcast();
        _writeAddresses(morpho, irm, usdc);
    }

    function _resolveLoanToken() private returns (address usdc, uint8 decimals) {
        usdc = vm.envOr("USDC", address(0));
        bool deployMock = vm.envOr("DEPLOY_MOCK_USDC", false);
        if (usdc == address(0)) {
            require(deployMock, "USDC required (mock token is opt-in)");
            require(_isDevOrTestChain(block.chainid), "MockUSDC restricted to dev/test chains");
            usdc = address(new MockUSDC());
            console.log("MockUSDC deployed:", usdc);
        } else {
            require(!deployMock, "provide USDC or enable DEPLOY_MOCK_USDC, not both");
        }
        require(usdc.code.length != 0, "USDC has no code");
        decimals = IERC20Metadata(usdc).decimals();
        require(decimals <= 18, "unsupported USDC decimals");
        uint256 expectedDecimals = vm.envOr("USDC_DECIMALS", type(uint256).max);
        if (expectedDecimals != type(uint256).max) require(expectedDecimals == decimals, "USDC decimals mismatch");
    }

    function _resolveMorpho(address deployer, address admin) private returns (address morpho, address irm) {
        morpho = vm.envOr("MORPHO", address(0));
        irm = vm.envOr("IRM", address(0));
        uint256 lltv = vm.envOr("LLTV", uint256(0.77e18));
        bool deployLocal = vm.envOr("DEPLOY_LOCAL_MORPHO", false);
        if (morpho == address(0)) {
            require(deployLocal, "MORPHO required (self-deploy is opt-in)");
            require(irm == address(0), "IRM must be empty for local Morpho deployment");
            require(lltv > 0 && lltv <= 0.9e18, "invalid LLTV");
            morpho = deployCode("out/Morpho.sol/Morpho.json", abi.encode(deployer));
            irm = deployCode("out/AdaptiveCurveIrm.sol/AdaptiveCurveIrm.json", abi.encode(morpho));
            IMorpho(morpho).enableIrm(irm);
            IMorpho(morpho).enableLltv(lltv);
            if (admin != deployer) IMorpho(morpho).setOwner(admin);
            console.log("Self-deployed Morpho Blue:", morpho);
            console.log("Self-deployed AdaptiveCurveIrm:", irm);
        } else {
            require(!deployLocal, "MORPHO supplied; disable DEPLOY_LOCAL_MORPHO");
            require(irm != address(0), "IRM required with MORPHO");
            require(morpho.code.length != 0, "MORPHO has no code");
            require(irm.code.length != 0, "IRM has no code");
            require(IMorpho(morpho).isIrmEnabled(irm), "IRM is not enabled on Morpho");
            require(IMorpho(morpho).isLltvEnabled(lltv), "LLTV is not enabled on Morpho");
        }
    }

    function _configureStableGuard() private {
        address stableFeed = vm.envOr("STABLE_FEED", address(0));
        uint256 floor = vm.envOr("STABLE_FLOOR", uint256(0));
        uint256 maxStaleness = vm.envOr("STABLE_MAX_STALENESS", uint256(1 days));
        if (stableFeed == address(0)) {
            require(floor == 0, "STABLE_FLOOR requires STABLE_FEED");
            require(
                _isDevOrTestChain(block.chainid) || vm.envOr("ALLOW_UNGUARDED_STABLE", false),
                "STABLE_FEED required on production (or explicitly allow unguarded stablecoin)"
            );
            return;
        }
        require(stableFeed.code.length != 0, "STABLE_FEED has no code");
        require(floor != 0 && maxStaleness != 0, "stable guard params required");
        adapter.setStableGuard(stableFeed, floor, maxStaleness);
    }

    function _writeAddresses(address morpho, address irm, address usdc) internal {
        string memory k = "tensile";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "Morpho", morpho);
        vm.serializeAddress(k, "AdaptiveCurveIrm", irm);
        vm.serializeAddress(k, "USDC", usdc);
        vm.serializeAddress(k, "C01_TensileAccessManager", address(accessManager));
        vm.serializeAddress(k, "C02_IdentityRegistry", address(identity));
        vm.serializeAddress(k, "C03_WarehouseRegistry", address(warehouses));
        vm.serializeAddress(k, "C05_AttestationRegistry", address(attestations));
        vm.serializeAddress(k, "C06_MaterialPassport", address(passport));
        vm.serializeAddress(k, "C07_MintingController", address(controller));
        vm.serializeAddress(k, "C08_RedemptionManager", address(redemption));
        vm.serializeAddress(k, "C10_ReserveGuard", address(guard));
        vm.serializeAddress(k, "C11_PriceOracleAdapter", address(adapter));
        vm.serializeAddress(k, "C12_MarketRegistry", address(registry));
        vm.serializeAddress(k, "C15_CreditRouter", address(router));
        vm.serializeAddress(k, "C16_Marketplace", address(marketplace));
        vm.serializeAddress(k, "C18_FeeCollector", address(fees));
        vm.serializeAddress(k, "C19_PriceIndex", address(index));
        string memory json = vm.serializeAddress(k, "C14b_TensileCreditVault", address(vault));
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console.log("Addresses written to", path);

        // Keep the broadcast output self-contained so operators can capture the
        // complete deployment without having to open the JSON artifact.
        console.log("Deployment addresses (chainId):", block.chainid);
        console.log("Morpho:", morpho);
        console.log("AdaptiveCurveIrm:", irm);
        console.log("USDC:", usdc);
        console.log("C01_TensileAccessManager:", address(accessManager));
        console.log("C02_IdentityRegistry:", address(identity));
        console.log("C03_WarehouseRegistry:", address(warehouses));
        console.log("C05_AttestationRegistry:", address(attestations));
        console.log("C06_MaterialPassport:", address(passport));
        console.log("C07_MintingController:", address(controller));
        console.log("C08_RedemptionManager:", address(redemption));
        console.log("C10_ReserveGuard:", address(guard));
        console.log("C11_PriceOracleAdapter:", address(adapter));
        console.log("C12_MarketRegistry:", address(registry));
        console.log("C15_CreditRouter:", address(router));
        console.log("C16_Marketplace:", address(marketplace));
        console.log("C18_FeeCollector:", address(fees));
        console.log("C19_PriceIndex:", address(index));
        console.log("C14b_TensileCreditVault:", address(vault));
    }

    function _isDevOrTestChain(uint256 chainId) private pure returns (bool) {
        return chainId == 31337 || chainId == 1337 || chainId == 11155111 || chainId == 10143 || chainId == 42431 || chainId == 421614 || chainId == 1338 || chainId == 99801 || chainId == 84532 || chainId == 46630;
    }
}
