#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")/.."

if grep -RInE '\.(call|delegatecall|staticcall)[[:space:]]*\([^)]*(routerCalldata|routerData|calldata|payload)|\b(call|delegatecall)[[:space:]]*\([^)]*(routerCalldata|routerData|calldata|payload)' src --include='*.sol'; then
    echo "SG8 failed: generic call with caller-provided bytes found under src/" >&2
    exit 1
fi

echo "SG8 pass: no generic call with caller-provided bytes found under src/"
