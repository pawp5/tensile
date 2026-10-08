// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho} from "morpho-blue/interfaces/IMorpho.sol";

import {TensileAccessManager} from "../src/access/TensileAccessManager.sol";
import {Roles} from "../src/access/Roles.sol";
import {ITensileAccess} from "../src/interfaces/ITensileAccess.sol";
import {IdentityRegistry} from "../src/identity/IdentityRegistry.sol";
import {WarehouseRegistry} from "../src/asset/WarehouseRegistry.sol";
import {AttestationRegistry} from "../src/asset/AttestationRegistry.sol";
import {MaterialPassport} from "../src/asset/MaterialPassport.sol";
import {MintingController} from "../src/asset/MintingController.sol";
import {RedemptionManager} from "../src/asset/RedemptionManager.sol";
import {ReserveGuard} from "../src/reserve/ReserveGuard.sol";
import {PriceOracleAdapter} from "../src/pricing/PriceOracleAdapter.sol";
import {MarketRegistry} from "../src/credit/MarketRegistry.sol";
import {CreditRouter} from "../src/credit/CreditRouter.sol";
import {Marketplace} from "../src/market/Marketplace.sol";
import {FeeCollector} from "../src/market/FeeCollector.sol";
import {PriceIndex} from "../src/market/PriceIndex.sol";
import {TensileCreditVault} from "../src/credit/TensileCreditVault.sol";
import {ITensileCreditVault} from "../src/interfaces/ITensileCreditVault.sol";
import {IMaterialPassport} from "../src/interfaces/IMaterialPassport.sol";
import {IIdentityRegistry} from "../src/interfaces/IIdentityRegistry.sol";
import {IWarehouseRegistry} from "../src/interfaces/IWarehouseRegistry.sol";
import {IAttestationRegistry} from "../src/interfaces/IAttestationRegistry.sol";
import {IReserveGuard} from "../src/interfaces/IReserveGuard.sol";
import {IPriceOracleAdapter} from "../src/interfaces/IPriceOracleAdapter.sol";
import {IMarketRegistry} from "../src/interfaces/IMarketRegistry.sol";
import {ICreditRouter} from "../src/interfaces/ICreditRouter.sol";
import {IFeeCollector} from "../src/interfaces/IFeeCollector.sol";
import {IPriceIndex} from "../src/interfaces/IPriceIndex.sol";

/// @notice Shared deployment + wiring logic used by Deploy.s.sol and DemoFlow.s.sol.
abstract contract TensileDeployer is Script {
    struct DeployConfig {
        address morpho;
        address irm;
        address usdc;
        uint8 usdcDecimals;
        uint256 reserveMaxStaleness;
        string passportBaseURI;
    }

    TensileAccessManager public accessManager;
    IdentityRegistry public identity;
    WarehouseRegistry public warehouses;
    AttestationRegistry public attestations;
    MaterialPassport public passport;
    ReserveGuard public guard;
    FeeCollector public fees;
    MintingController public controller;
    RedemptionManager public redemption;
    PriceOracleAdapter public adapter;
    MarketRegistry public registry;
    CreditRouter public router;
    PriceIndex public index;
    Marketplace public marketplace;
    TensileCreditVault public vault;

    /// @dev Must be called by an account that will be ADMIN of the new AccessManager (inside a broadcast or prank).
    function _deployTensile(DeployConfig memory c, address admin) internal {
        accessManager = new TensileAccessManager(admin);
        ITensileAccess a = ITensileAccess(address(accessManager));

        identity = new IdentityRegistry(a);
        warehouses = new WarehouseRegistry(a);
        attestations = new AttestationRegistry(a);
        passport = new MaterialPassport(a, IIdentityRegistry(address(identity)), IWarehouseRegistry(address(warehouses)), c.passportBaseURI);
        guard = new ReserveGuard(a, IWarehouseRegistry(address(warehouses)), IMaterialPassport(address(passport)), c.reserveMaxStaleness);
        fees = new FeeCollector(a);
        controller = new MintingController(
            a,
            IMaterialPassport(address(passport)),
            IWarehouseRegistry(address(warehouses)),
            IAttestationRegistry(address(attestations)),
            IReserveGuard(address(guard)),
            IIdentityRegistry(address(identity))
        );
        redemption = new RedemptionManager(
            a,
            IMaterialPassport(address(passport)),
            IWarehouseRegistry(address(warehouses)),
            IAttestationRegistry(address(attestations)),
            IIdentityRegistry(address(identity))
        );
        adapter = new PriceOracleAdapter(a, IMaterialPassport(address(passport)), c.usdcDecimals);
        registry = new MarketRegistry(
            a, IMorpho(c.morpho), c.usdc, c.irm, IMaterialPassport(address(passport)), IIdentityRegistry(address(identity))
        );
        router = new CreditRouter(
            a,
            IMorpho(c.morpho),
            IMarketRegistry(address(registry)),
            IMaterialPassport(address(passport)),
            IPriceOracleAdapter(address(adapter)),
            IReserveGuard(address(guard)),
            IIdentityRegistry(address(identity)),
            IERC20(c.usdc),
            IFeeCollector(address(fees))
        );
        index = new PriceIndex(a);
        vault = new TensileCreditVault(a, IMorpho(c.morpho), IMarketRegistry(address(registry)), IMaterialPassport(address(passport)), IERC20(c.usdc));
        marketplace = new Marketplace(
            a,
            IMaterialPassport(address(passport)),
            IIdentityRegistry(address(identity)),
            ICreditRouter(address(router)),
            IERC20(c.usdc),
            c.usdcDecimals,
            IFeeCollector(address(fees))
        );

        // ---- wiring
        attestations.setPassport(IMaterialPassport(address(passport)));
        passport.setAttestationRegistry(address(attestations));
        router.setMarketplace(address(marketplace));
        router.setVault(ITensileCreditVault(address(vault)));
        vault.setRouter(address(router));
        registry.setRouter(address(router));
        marketplace.setPriceIndex(IPriceIndex(address(index)));

        // ---- contract-to-contract roles
        accessManager.grantRole(Roles.MINTER, address(controller));
        accessManager.grantRole(Roles.REDEEMER, address(redemption));
        accessManager.grantRole(Roles.RECORDER, address(controller));
        accessManager.grantRole(Roles.RECORDER, address(redemption));
        accessManager.grantRole(Roles.GUARDIAN, address(guard));
        accessManager.grantRole(Roles.REGISTRAR, address(registry));
        accessManager.grantRole(Roles.FEE_NOTIFIER, address(controller));
        accessManager.grantRole(Roles.FEE_NOTIFIER, address(router));
        accessManager.grantRole(Roles.FEE_NOTIFIER, address(marketplace));
        accessManager.grantRole(Roles.FEE_NOTIFIER, address(vault));
        accessManager.grantRole(Roles.INDEX_RECORDER, address(marketplace));

        // ---- protocol contracts allowed to custody lots / wrapper tokens
        identity.setProtocol(address(router), true);
        identity.setProtocol(address(vault), true);
        identity.setProtocol(c.morpho, true);
    }
}
