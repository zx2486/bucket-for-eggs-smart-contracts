#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo "Missing .env; configure SEPOLIA_RPC_URL and BUCKET_INFO_ADDRESS." >&2
  exit 1
fi
set -a
source .env
set +a
: "${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL is required}"
BUCKET_INFO_ADDRESS="${1:-${BUCKET_INFO_ADDRESS:-}}"
: "${BUCKET_INFO_ADDRESS:?Pass an address or set BUCKET_INFO_ADDRESS in .env}"

if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
  forge verify-contract \
    --chain-id 11155111 \
    --compiler-version v0.8.33 \
    --num-of-optimizations 1 \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    "$BUCKET_INFO_ADDRESS" \
    src/BucketInfo.sol:BucketInfo || echo "Verification failed or the contract may already be verified."
fi

export BUCKET_INFO_ADDRESS
forge script script/VerifyBucketInfo.s.sol:VerifyBucketInfo --rpc-url "$SEPOLIA_RPC_URL" -vvv
printf 'Etherscan: https://sepolia.etherscan.io/address/%s\n' "$BUCKET_INFO_ADDRESS"
