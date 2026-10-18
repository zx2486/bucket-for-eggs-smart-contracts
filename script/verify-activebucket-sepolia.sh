#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then echo "Missing .env" >&2; exit 1; fi
set -a; source .env; set +a
: "${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL is required}"
: "${ACTIVE_BUCKET_PROXY_ADDRESS:?Set ACTIVE_BUCKET_PROXY_ADDRESS in .env}"
: "${ACTIVE_BUCKET_IMPL_ADDRESS:?Set ACTIVE_BUCKET_IMPL_ADDRESS in .env}"
: "${ACTIVE_BUCKET_FACTORY_ADDRESS:?Set ACTIVE_BUCKET_FACTORY_ADDRESS in .env}"

read -r BUCKET_INFO REGISTRY < <(python3 - <<'PY'
import json
c=json.load(open("configs/sepolia.json"))["deployment"]
print(c["bucketInfoAddress"], c["implementationRegistryAddress"])
PY
)

if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  forge verify-contract --chain-id 11155111 --compiler-version v0.8.33 --num-of-optimizations 1 \
    --constructor-args "$(cast abi-encode 'constructor(address)' "$REGISTRY")" \
    "$ACTIVE_BUCKET_IMPL_ADDRESS" src/ActiveBucket.sol:ActiveBucket --etherscan-api-key "$ETHERSCAN_API_KEY" || true
  forge verify-contract --chain-id 11155111 --compiler-version v0.8.33 --num-of-optimizations 1 \
    --constructor-args "$(cast abi-encode 'constructor(address,address)' "$ACTIVE_BUCKET_IMPL_ADDRESS" "$BUCKET_INFO")" \
    "$ACTIVE_BUCKET_FACTORY_ADDRESS" src/ActiveBucketFactory.sol:ActiveBucketFactory --etherscan-api-key "$ETHERSCAN_API_KEY" || true
fi
export ACTIVE_BUCKET_PROXY_ADDRESS ACTIVE_BUCKET_FACTORY_ADDRESS
forge script script/VerifyActiveBucket.s.sol:VerifyActiveBucket --rpc-url "$SEPOLIA_RPC_URL" -vvv
