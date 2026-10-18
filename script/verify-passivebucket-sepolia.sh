#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then echo "Missing .env" >&2; exit 1; fi
set -a; source .env; set +a
: "${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL is required}"
: "${PASSIVE_BUCKET_PROXY_ADDRESS:?Set PASSIVE_BUCKET_PROXY_ADDRESS in .env}"
: "${PASSIVE_BUCKET_IMPL_ADDRESS:?Set PASSIVE_BUCKET_IMPL_ADDRESS in .env}"
: "${PASSIVE_BUCKET_FACTORY_ADDRESS:?Set PASSIVE_BUCKET_FACTORY_ADDRESS in .env}"

read -r BUCKET_INFO REGISTRY < <(python3 - <<'PY'
import json
c=json.load(open("configs/sepolia.json"))["deployment"]
print(c["bucketInfoAddress"], c["implementationRegistryAddress"])
PY
)

if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  forge verify-contract --chain-id 11155111 --compiler-version v0.8.33 --num-of-optimizations 1 \
    --constructor-args "$(cast abi-encode 'constructor(address)' "$REGISTRY")" \
    "$PASSIVE_BUCKET_IMPL_ADDRESS" src/PassiveBucket.sol:PassiveBucket --etherscan-api-key "$ETHERSCAN_API_KEY" || true
  forge verify-contract --chain-id 11155111 --compiler-version v0.8.33 --num-of-optimizations 1 \
    --constructor-args "$(cast abi-encode 'constructor(address,address)' "$PASSIVE_BUCKET_IMPL_ADDRESS" "$BUCKET_INFO")" \
    "$PASSIVE_BUCKET_FACTORY_ADDRESS" src/PassiveBucketFactory.sol:PassiveBucketFactory --etherscan-api-key "$ETHERSCAN_API_KEY" || true
fi
export PASSIVE_BUCKET_PROXY_ADDRESS PASSIVE_BUCKET_FACTORY_ADDRESS
forge script script/VerifyPassiveBucket.s.sol:VerifyPassiveBucket --rpc-url "$SEPOLIA_RPC_URL" -vvv
