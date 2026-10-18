#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then echo "Missing .env" >&2; exit 1; fi
set -a; source .env; set +a
: "${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL is required}"
: "${PURE_MEMBERSHIP_PROXY_ADDRESS:?Set PURE_MEMBERSHIP_PROXY_ADDRESS in .env}"
: "${PURE_MEMBERSHIP_IMPL_ADDRESS:?Set PURE_MEMBERSHIP_IMPL_ADDRESS in .env}"
: "${PURE_MEMBERSHIP_FACTORY_ADDRESS:?Set PURE_MEMBERSHIP_FACTORY_ADDRESS in .env}"

read -r BUCKET_INFO REGISTRY < <(python3 - <<'PY'
import json
c=json.load(open("configs/sepolia.json"))["deployment"]
print(c["bucketInfoAddress"], c["implementationRegistryAddress"])
PY
)

if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  forge verify-contract --chain-id 11155111 --compiler-version v0.8.33 --num-of-optimizations 1 \
    --constructor-args "$(cast abi-encode 'constructor(address)' "$REGISTRY")" \
    "$PURE_MEMBERSHIP_IMPL_ADDRESS" src/PureMembership.sol:PureMembership --etherscan-api-key "$ETHERSCAN_API_KEY" || true
  forge verify-contract --chain-id 11155111 --compiler-version v0.8.33 --num-of-optimizations 1 \
    --constructor-args "$(cast abi-encode 'constructor(address,address)' "$PURE_MEMBERSHIP_IMPL_ADDRESS" "$BUCKET_INFO")" \
    "$PURE_MEMBERSHIP_FACTORY_ADDRESS" src/PureMembershipFactory.sol:PureMembershipFactory --etherscan-api-key "$ETHERSCAN_API_KEY" || true
fi
export PURE_MEMBERSHIP_PROXY_ADDRESS PURE_MEMBERSHIP_FACTORY_ADDRESS
forge script script/VerifyPureMembership.s.sol:VerifyPureMembership --rpc-url "$SEPOLIA_RPC_URL" -vvv
