#!/bin/bash

# Verify ActiveBucket + ActiveBucketFactory contracts on Sepolia (Etherscan + on-chain state)

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== ActiveBucket Contract Verification ===${NC}"
echo ""

# ── Environment ─────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi
source .env

# Required
if [ -z "$ACTIVE_BUCKET_PROXY_ADDRESS" ]; then
    echo -e "${RED}Error: ACTIVE_BUCKET_PROXY_ADDRESS not set in .env${NC}"
    echo "Add: ACTIVE_BUCKET_PROXY_ADDRESS=0x..."
    exit 1
fi
if [ -z "$SEPOLIA_RPC_URL" ]; then
    echo -e "${RED}Error: SEPOLIA_RPC_URL not set in .env${NC}"
    exit 1
fi

echo -e "${YELLOW}Addresses:${NC}"
echo "  Proxy (ActiveBucket)   : $ACTIVE_BUCKET_PROXY_ADDRESS"
[ -n "$ACTIVE_BUCKET_IMPL_ADDRESS"    ] && echo "  Implementation         : $ACTIVE_BUCKET_IMPL_ADDRESS"
[ -n "$ACTIVE_BUCKET_FACTORY_ADDRESS" ] && echo "  Factory                : $ACTIVE_BUCKET_FACTORY_ADDRESS"
echo ""

# ── Step 1: Etherscan verification ──────────────────────────────────────────
echo -e "${YELLOW}Step 1: Verifying contracts on Etherscan...${NC}"
echo ""

if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo -e "${YELLOW}  ETHERSCAN_API_KEY not set – skipping Etherscan verification.${NC}"
else
    # Verify implementation (no constructor args)
    if [ -n "$ACTIVE_BUCKET_IMPL_ADDRESS" ]; then
        echo "  Verifying ActiveBucket implementation..."
        forge verify-contract \
            --chain-id 11155111 \
            --num-of-optimizations 200 \
            --compiler-version 0.8.33 \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            "$ACTIVE_BUCKET_IMPL_ADDRESS" \
            src/ActiveBucket.sol:ActiveBucket \
            || echo "  (May already be verified)"
        echo ""
    fi

    # Verify factory (constructor arg: address implementation_)
    if [ -n "$ACTIVE_BUCKET_FACTORY_ADDRESS" ] && [ -n "$ACTIVE_BUCKET_IMPL_ADDRESS" ]; then
        echo "  Verifying ActiveBucketFactory..."
        forge verify-contract \
            --chain-id 11155111 \
            --num-of-optimizations 200 \
            --compiler-version 0.8.33 \
            --etherscan-api-key "$ETHERSCAN_API_KEY" \
            --constructor-args "$(cast abi-encode 'constructor(address)' "$ACTIVE_BUCKET_IMPL_ADDRESS")" \
            "$ACTIVE_BUCKET_FACTORY_ADDRESS" \
            src/ActiveBucketFactory.sol:ActiveBucketFactory \
            || echo "  (May already be verified)"
        echo ""
    fi

    echo "  Note: ERC-1967 proxy verification is typically handled automatically by Etherscan."
    echo "        If needed, use the Etherscan UI 'Is this a proxy?' feature:"
    echo "        https://sepolia.etherscan.io/address/$ACTIVE_BUCKET_PROXY_ADDRESS#code"
fi
echo ""

# ── Step 2: On-chain state via Solidity script ───────────────────────────────
echo -e "${YELLOW}Step 2: Reading on-chain state...${NC}"
echo ""

export ACTIVE_BUCKET_PROXY_ADDRESS
export ACTIVE_BUCKET_FACTORY_ADDRESS

forge script script/VerifyActiveBucket.s.sol:VerifyActiveBucket \
    --rpc-url "$SEPOLIA_RPC_URL" \
    -vvv

echo ""
echo -e "${GREEN}=== Verification Complete ===${NC}"
echo ""
echo "Etherscan links:"
echo "  Proxy   : https://sepolia.etherscan.io/address/$ACTIVE_BUCKET_PROXY_ADDRESS"
[ -n "$ACTIVE_BUCKET_IMPL_ADDRESS"    ] && echo "  Impl    : https://sepolia.etherscan.io/address/$ACTIVE_BUCKET_IMPL_ADDRESS"
[ -n "$ACTIVE_BUCKET_FACTORY_ADDRESS" ] && echo "  Factory : https://sepolia.etherscan.io/address/$ACTIVE_BUCKET_FACTORY_ADDRESS"
echo ""
