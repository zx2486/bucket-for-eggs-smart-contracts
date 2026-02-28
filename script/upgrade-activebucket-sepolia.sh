#!/bin/bash

# Upgrade the existing ActiveBucket UUPS proxy to the latest implementation.
#
# Required .env variables:
#   PRIVATE_KEY                  – deployer private key (must be proxy owner)
#   SEPOLIA_RPC_URL              – Sepolia RPC endpoint
#   ACTIVE_BUCKET_PROXY_ADDRESS  – address of the existing ERC1967 proxy
#
# Optional .env variables:
#   ETHERSCAN_API_KEY            – enables automatic Etherscan verification

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}=== ActiveBucket Upgrade – Sepolia ===${NC}"
echo ""

# ── Environment checks ───────────────────────────────────────────────────────
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi
source .env

for var in PRIVATE_KEY SEPOLIA_RPC_URL ACTIVE_BUCKET_PROXY_ADDRESS; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: $var is not set in .env${NC}"
        exit 1
    fi
done

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
AB="$ACTIVE_BUCKET_PROXY_ADDRESS"

# ── Pre-upgrade state ────────────────────────────────────────────────────────
echo -e "${CYAN}Pre-upgrade state:${NC}"
echo "  Proxy address  : $AB"
echo "  Caller         : $DEPLOYER"

PROXY_OWNER=$(cast call "$AB" "owner()(address)" --rpc-url "$SEPOLIA_RPC_URL")
echo "  Proxy owner    : $PROXY_OWNER"

if [ "$(echo "$PROXY_OWNER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$DEPLOYER" | tr '[:upper:]' '[:lower:]')" ]; then
    echo -e "${RED}Error: caller ($DEPLOYER) is not the proxy owner ($PROXY_OWNER)${NC}"
    exit 1
fi

IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
CURRENT_IMPL=$(cast storage "$AB" "$IMPL_SLOT" --rpc-url "$SEPOLIA_RPC_URL")
CURRENT_IMPL_ADDR="0x$(echo "$CURRENT_IMPL" | tail -c 41)"
echo "  Current impl   : $CURRENT_IMPL_ADDR"

BUCKET_INFO=$(cast call "$AB" "bucketInfo()(address)" --rpc-url "$SEPOLIA_RPC_URL")
ONE_INCH=$(cast call "$AB" "oneInchRouter()(address)" --rpc-url "$SEPOLIA_RPC_URL")
PERF_FEE=$(cast call "$AB" "performanceFeeBps()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')
TOKEN_PRICE=$(cast call "$AB" "tokenPrice()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')
TOTAL_SUPPLY=$(cast call "$AB" "totalSupply()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')
echo "  BucketInfo     : $BUCKET_INFO"
echo "  1inch router   : $ONE_INCH"
echo "  Perf fee (bps) : $PERF_FEE"
echo "  Token price    : $TOKEN_PRICE"
echo "  Total supply   : $TOTAL_SUPPLY"
echo ""

# ── Confirmation ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}This will deploy a new ActiveBucket implementation and upgrade the proxy.${NC}"
echo -e "${YELLOW}All existing state (owner, bucketInfo, balances, shares) will be preserved.${NC}"
echo ""
read -p "Proceed? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ── Run upgrade ──────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}Running upgrade...${NC}"

FORGE_ARGS=(
    script script/UpgradeActiveBucketSepolia.s.sol
    --rpc-url "$SEPOLIA_RPC_URL"
    --private-key "$PRIVATE_KEY"
    --broadcast
    -vvv
)

if [ -n "$ETHERSCAN_API_KEY" ]; then
    FORGE_ARGS+=(--verify --etherscan-api-key "$ETHERSCAN_API_KEY")
    echo "  (Etherscan verification enabled)"
fi

forge "${FORGE_ARGS[@]}"

# ── Extract new implementation address from broadcast ────────────────────────
BROADCAST_FILE="broadcast/UpgradeActiveBucketSepolia.s.sol/11155111/run-latest.json"
if [ -f "$BROADCAST_FILE" ]; then
    NEW_IMPL=$(cat "$BROADCAST_FILE" \
        | grep -o '"contractAddress":"0x[^"]*"' \
        | head -1 \
        | grep -o '0x[^"]*')
else
    NEW_IMPL=$(cast storage "$AB" "$IMPL_SLOT" --rpc-url "$SEPOLIA_RPC_URL")
    NEW_IMPL="0x$(echo "$NEW_IMPL" | tail -c 41)"
fi

# ── Post-upgrade verification ─────────────────────────────────────────────────
echo ""
echo -e "${GREEN}=== Post-Upgrade Verification ===${NC}"

NEW_IMPL_ONCHAIN=$(cast storage "$AB" "$IMPL_SLOT" --rpc-url "$SEPOLIA_RPC_URL")
NEW_IMPL_ADDR="0x$(echo "$NEW_IMPL_ONCHAIN" | tail -c 41)"
echo "  Proxy address      : $AB"
echo "  New implementation : $NEW_IMPL_ADDR"

POST_OWNER=$(cast call "$AB" "owner()(address)" --rpc-url "$SEPOLIA_RPC_URL")
POST_BI=$(cast call "$AB" "bucketInfo()(address)" --rpc-url "$SEPOLIA_RPC_URL")
POST_ROUTER=$(cast call "$AB" "oneInchRouter()(address)" --rpc-url "$SEPOLIA_RPC_URL")
POST_FEE=$(cast call "$AB" "performanceFeeBps()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')
POST_PRICE=$(cast call "$AB" "tokenPrice()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')
POST_SUPPLY=$(cast call "$AB" "totalSupply()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')

echo "  Owner (preserved)        : $POST_OWNER"
echo "  BucketInfo (preserved)   : $POST_BI"
echo "  1inch router (preserved) : $POST_ROUTER"
echo "  Perf fee bps (preserved) : $POST_FEE"
echo "  Token price (preserved)  : $POST_PRICE"
echo "  Total supply (preserved) : $POST_SUPPLY"

# State preservation checks
FAIL=0
[ "$(echo "$POST_OWNER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$PROXY_OWNER" | tr '[:upper:]' '[:lower:]')" ] && echo -e "${RED}  ✗ Owner changed!${NC}" && FAIL=1
[ "$(echo "$POST_BI" | tr '[:upper:]' '[:lower:]')" != "$(echo "$BUCKET_INFO" | tr '[:upper:]' '[:lower:]')" ] && echo -e "${RED}  ✗ BucketInfo changed!${NC}" && FAIL=1
[ "$POST_FEE" != "$PERF_FEE" ] && echo -e "${RED}  ✗ Performance fee changed!${NC}" && FAIL=1
[ "$POST_SUPPLY" != "$TOTAL_SUPPLY" ] && echo -e "${RED}  ✗ Total supply changed!${NC}" && FAIL=1

if [ $FAIL -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ All state preserved. Upgrade successful!${NC}"
else
    echo ""
    echo -e "${RED}✗ State mismatch detected. Review the upgrade carefully.${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Update ACTIVE_BUCKET_IMPL_ADDRESS in .env to: $NEW_IMPL_ADDR"
echo "  2. Run integration tests: ./script/test-activebucket-sepolia.sh"
if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo "  3. Verify manually: forge verify-contract $NEW_IMPL_ADDR src/ActiveBucket.sol:ActiveBucket --chain sepolia"
fi
