// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.19;

// Compile these deployment artifacts as independent test sources so DemoFlow's deployCode calls can resolve them.
import {Morpho} from "morpho-blue/Morpho.sol";
import {AdaptiveCurveIrm} from "morpho-blue-irm/adaptive-curve-irm/AdaptiveCurveIrm.sol";

contract MorphoArtifacts {}
