// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

// Forces Foundry to compile Morpho Blue + AdaptiveCurveIrm so scripts can `deployCode` them on networks where
// Morpho is not deployed (Monad testnet, local anvil). On Monad mainnet use the official Morpho addresses.
import {Morpho} from "morpho-blue/Morpho.sol";
import {AdaptiveCurveIrm} from "morpho-blue-irm/adaptive-curve-irm/AdaptiveCurveIrm.sol";
