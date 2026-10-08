// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {console} from "forge-std/console.sol";
import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";
import {TensileDeployer} from "./TensileDeployer.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Roles} from "../src/access/Roles.sol";

/// @notice Deploys the full Tensile protocol.
///
/// Env:
///   PRIVATE_KEY   deployer key (required)
///   ADMIN         final admin (Safe). Defaults to deployer. Deployer keeps ADMIN until you run the handover.
///   USDC          loan token. If unset -> deploys MockUSDC (TESTNET ONLY).
///   MORPHO, IRM   official Morpho Blue + AdaptiveCurveIrm addresses. If MORPHO is unset -> deploys our own
///                 Morpho Blue + IRM from lib (testnet / local only) and enables IRM + LLTV.
///   LLTV          LLTV to enable on a self-deployed Morpho (default 0.77e18).
///   BASE_URI      passport metadata base URI (Lot Explorer), default "https://tensile.app/lot/".
///   RESERVE_MAX_STALENESS seconds (default 86400).
///
/// Run:
///   forge script script/Deploy.s.sol --rpc-url monad_testnet --broadcast
contract Deploy is TensileDeployer {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address admin = vm.envOr("ADMIN", deployer);
        address usdc = vm.envOr("USDC", address(0));
        address morpho = vm.envOr("MORPHO", address(0));
        address irm = vm.envOr("IRM", address(0));
        uint256 lltv = vm.envOr("LLTV", uint256(0.77e18));
        string memory baseURI = vm.envOr("BASE_URI", string("https://tensile.app/lot/"));
        uint256 staleness = vm.envOr("RESERVE_MAX_STALENESS", uint256(1 days));

        vm.startBroadcast(pk);

        uint8 decimals = 6;
        if (usdc == address(0)) {
            usdc = address(new MockUSDC());
            console.log("MockUSDC deployed (testnet only):", usdc);
        }

        if (morpho == address(0)) {
            morpho = deployCode("Morpho.sol:Morpho", abi.encode(deployer));
            irm = deployCode("AdaptiveCurveIrm.sol:AdaptiveCurveIrm", abi.encode(morpho));
            IMorpho(morpho).enableIrm(irm);
            IMorpho(morpho).enableLltv(lltv);
            console.log("Self-deployed Morpho Blue:", morpho);
            console.log("Self-deployed AdaptiveCurveIrm:", irm);
        } else {
            require(irm != address(0), "IRM required with MORPHO");
        }

        _deployTensile(
            DeployConfig({
                morpho: morpho,
                irm: irm,
                usdc: usdc,
                usdcDecimals: decimals,
                reserveMaxStaleness: staleness,
                passportBaseURI: baseURI
            }),
            deployer
        );

        if (admin != deployer) {
            accessManager.grantRole(Roles.ADMIN, admin);
            console.log("ADMIN granted to", admin, "- revoke deployer after verifying the deployment");
        }

        vm.stopBroadcast();
        _writeAddresses(morpho, irm, usdc);
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
    }
}
