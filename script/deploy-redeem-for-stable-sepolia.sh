#!/usr/bin/env bash

set -euo pipefail

if [[ -z "${PRIVATE_KEY:-}" || -z "${SEPOLIA_RPC_URL:-}" ]]; then
    echo "Set PRIVATE_KEY and SEPOLIA_RPC_URL in the shell environment; this script does not read .env." >&2
    exit 1
fi

broadcast_args=()
if [[ "${1:-}" == "--broadcast" ]]; then
    if [[ "${CONFIRM_SEPOLIA_REDEEM_FOR_STABLE_DEPLOY:-}" != "YES" ]]; then
        echo "Set CONFIRM_SEPOLIA_REDEEM_FOR_STABLE_DEPLOY=YES to authorize broadcasting." >&2
        exit 1
    fi
    broadcast_args+=(--broadcast)
elif [[ "$#" -gt 0 ]]; then
    echo "Usage: $0 [--broadcast]" >&2
    exit 2
fi

forge script script/DeployRedeemForStableSepolia.s.sol \
    --rpc-url "$SEPOLIA_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    "${broadcast_args[@]}" \
    --gas-estimate-multiplier "${SEPOLIA_PASSIVEBUCKET_GAS_MULTIPLIER:-800}" \
    --verify \
    ${ETHERSCAN_API_KEY:+--etherscan-api-key "$ETHERSCAN_API_KEY"} \
    -vvv