#!/usr/bin/env bash
# Installs dependencies in this Foundry project without changing Git submodule state.
set -euo pipefail
forge install --no-git foundry-rs/forge-std
forge install --no-git OpenZeppelin/openzeppelin-contracts@v5.1.0
forge install --no-git morpho-org/morpho-blue
forge install --no-git morpho-org/morpho-blue-irm
forge build
