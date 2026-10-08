#!/usr/bin/env bash
# Installs dependencies. Run once from the contracts/ folder.
# Inside a git repo these become submodules; pin them to tags/commits before audit.
set -euo pipefail
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts@v5.1.0
forge install morpho-org/morpho-blue
forge install morpho-org/morpho-blue-irm
forge build
