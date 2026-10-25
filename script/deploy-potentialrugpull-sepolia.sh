#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "Missing .env; copy .env.example and configure PRIVATE_KEY and SEPOLIA_RPC_URL." >&2
  exit 1
fi
set -a
source .env
set +a
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL is required}"

args=(script script/DeployPotentialRugpullSepolia.s.sol:DeployPotentialRugpullSepolia --rpc-url "$SEPOLIA_RPC_URL" --private-key "$PRIVATE_KEY" --broadcast --gas-estimate-multiplier "${SEPOLIA_POTENTIALRUGPULL_GAS_MULTIPLIER:-800}" -vvv)
if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  args+=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
fi
forge "${args[@]}"
