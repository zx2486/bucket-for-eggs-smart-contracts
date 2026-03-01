#!/bin/bash

# Call updateBucketDistributions() on the PassiveBucket proxy with a new distribution.
#
# Required .env variables:
#   PRIVATE_KEY                   – deployer private key (must be proxy owner)
#   SEPOLIA_RPC_URL               – Sepolia RPC endpoint
#   PASSIVE_BUCKET_PROXY_ADDRESS  – address of the existing ERC1967 proxy

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}=== PassiveBucket Update Distributions – Sepolia ===${NC}"
echo ""

# ── Environment checks ───────────────────────────────────────────────────────
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi
source .env

for var in PRIVATE_KEY SEPOLIA_RPC_URL PASSIVE_BUCKET_PROXY_ADDRESS; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: $var is not set in .env${NC}"
        exit 1
    fi
done

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
PB="$PASSIVE_BUCKET_PROXY_ADDRESS"

# ── Auth check ───────────────────────────────────────────────────────────────
PROXY_OWNER=$(cast call "$PB" "owner()(address)" --rpc-url "$SEPOLIA_RPC_URL")
if [ "$(echo "$PROXY_OWNER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$DEPLOYER" | tr '[:upper:]' '[:lower:]')" ]; then
    echo -e "${RED}Error: caller ($DEPLOYER) is not the proxy owner ($PROXY_OWNER)${NC}"
    exit 1
fi

# ── New distribution ─────────────────────────────────────────────────────────
# Format: cast expects (address,uint256)[] as comma-separated tuples with no spaces
# Token 1: ETH        address(0)                                   50%
# Token 2: USDC     0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0  30%
# Token 3: LINK       0x779877A7B0D9E8603169DdbD7836e478b4624789  20%
NEW_DISTRIBUTIONS="[(0x0000000000000000000000000000000000000000,50),(0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0,30),(0x779877A7B0D9E8603169DdbD7836e478b4624789,20)]"

# ── Current state ────────────────────────────────────────────────────────────
echo -e "${CYAN}Current state:${NC}"
echo "  Proxy   : $PB"
echo "  Caller  : $DEPLOYER"
echo "  Owner   : $PROXY_OWNER"

DIST_COUNT=$(cast call "$PB" "getDistributionCount()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')
echo "  Current distribution count: $DIST_COUNT"
for i in $(seq 0 $((DIST_COUNT - 1))); do
    DIST=$(cast call "$PB" "getBucketDistributions()(address,uint256)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || true)
done

TOTAL_VALUE=$(cast call "$PB" "calculateTotalValue()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')
TOTAL_SUPPLY=$(cast call "$PB" "totalSupply()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')
TOKEN_PRICE=$(cast call "$PB" "tokenPrice()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')
echo "  Total value  : $TOTAL_VALUE (8 dec USD)"
echo "  Total supply : $TOTAL_SUPPLY"
echo "  Token price  : $TOKEN_PRICE"
echo ""

# ── New distribution summary ─────────────────────────────────────────────────
echo -e "${CYAN}New distribution to apply:${NC}"
echo "  50% → 0x0000000000000000000000000000000000000000 (ETH)"
echo "  30% → 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0 (USDC)"
echo "  20% → 0x779877A7B0D9E8603169DdbD7836e478b4624789 (LINK)"
echo ""

# ── Confirmation ─────────────────────────────────────────────────────────────
echo -e "${YELLOW}This will update the bucket distribution. The contract must be accountable (owner holds ≥5% of supply).${NC}"
read -p "Proceed? [y/N] " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# ── Send transaction ─────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}Sending updateBucketDistributions()...${NC}"

TX_RESULT=$(cast send "$PB" \
    "updateBucketDistributions((address,uint256)[])" \
    "$NEW_DISTRIBUTIONS" \
    --private-key "$PRIVATE_KEY" \
    --rpc-url "$SEPOLIA_RPC_URL" \
    --json 2>&1)

if echo "$TX_RESULT" | grep -q '"transactionHash"'; then
    TX_HASH=$(echo "$TX_RESULT" | grep -o '"transactionHash":"0x[^"]*"' | grep -o '0x[^"]*')
    echo "  TX hash : $TX_HASH"
    echo -e "  Waiting for confirmation..."
    cast receipt "$TX_HASH" --rpc-url "$SEPOLIA_RPC_URL" > /dev/null
    echo -e "  ${GREEN}✓ Confirmed${NC}"
else
    echo -e "${RED}Transaction failed:${NC}"
    echo "$TX_RESULT"
    exit 1
fi

# ── Post-update verification ──────────────────────────────────────────────────
echo ""
echo -e "${GREEN}=== Post-Update Verification ===${NC}"

NEW_DIST_COUNT=$(cast call "$PB" "getDistributionCount()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')
echo "  New distribution count: $NEW_DIST_COUNT"

NEW_TOTAL_VALUE=$(cast call "$PB" "calculateTotalValue()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" | awk '{print $1}')
echo "  Total value (unchanged): $NEW_TOTAL_VALUE (8 dec USD)"

if [ "$NEW_DIST_COUNT" = "3" ]; then
    echo ""
    echo -e "${GREEN}✓ Distribution updated successfully!${NC}"
else
    echo -e "${RED}✗ Unexpected distribution count: $NEW_DIST_COUNT (expected 3)${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "  1. Verify distribution on Etherscan: $PB"
echo "  2. Run rebalance if needed: ./script/test-passivebucket-sepolia.sh"
