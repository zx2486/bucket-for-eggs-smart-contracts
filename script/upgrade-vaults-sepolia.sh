#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")/.."

broadcast=false
if [[ "${1:-}" == "--broadcast" ]]; then
    broadcast=true
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--broadcast]" >&2
    exit 2
fi

: "${SEPOLIA_RPC_URL:?Export SEPOLIA_RPC_URL in your shell}"
: "${UPGRADE_PHASE:?Export UPGRADE_PHASE in your shell}"

args=(script script/UpgradeVaultsSepolia.s.sol --rpc-url "$SEPOLIA_RPC_URL" --gas-estimate-multiplier "${SEPOLIA_UPGRADE_GAS_MULTIPLIER:-400}" -vvv)
if [[ "${UPGRADE_PHASE:-}" == "check" || "${UPGRADE_PHASE:-}" == "snapshot" ]]; then
    if [[ -n "${UPGRADE_SCRIPT_SENDER:-}" ]]; then
        args+=(--sender "$UPGRADE_SCRIPT_SENDER")
    fi
    if [[ "${UPGRADE_PHASE:-}" == "check" ]]; then
        : "${UPGRADE_SNAPSHOT_JSON:?Export UPGRADE_SNAPSHOT_JSON for check phase}"
    fi
else
    : "${PRIVATE_KEY:?Export PRIVATE_KEY in your shell for a write phase}"
    args+=(--private-key "$PRIVATE_KEY")
fi
if $broadcast; then
    if [[ "${UPGRADE_PHASE:-}" == "check" || "${UPGRADE_PHASE:-}" == "snapshot" ]]; then
        echo "Read-only phases do not support --broadcast." >&2
        exit 2
    fi
    : "${PRIVATE_KEY:?Export PRIVATE_KEY in your shell for broadcast}"
    if [[ "${CONFIRM_SEPOLIA_VAULT_UPGRADE:-}" != "YES" ]]; then
        echo "Set CONFIRM_SEPOLIA_VAULT_UPGRADE=YES and pass --broadcast to submit transactions." >&2
        exit 1
    fi
    args+=(--broadcast)
else
    echo "Dry run only. Pass --broadcast and set CONFIRM_SEPOLIA_VAULT_UPGRADE=YES to submit transactions."
fi

forge "${args[@]}"
