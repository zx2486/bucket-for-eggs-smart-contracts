#!/bin/bash

# Verify and validate DefiSwap contract on Sepolia

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== DefiSwap Contract Verification ===${NC}"
echo ""

# Load environment variables
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

source .env

# Check if contract address is set
if [ -z "$DEFISWAP_ADDRESS" ]; then
    echo -e "${RED}Error: DEFISWAP_ADDRESS not set in .env${NC}"
    echo "Please add: DEFISWAP_ADDRESS=0x..."
    exit 1
fi

echo "Contract Address: $DEFISWAP_ADDRESS"
echo "Network: Sepolia"
echo ""

# Step 1: Verify on Etherscan (if not already verified)
echo -e "${YELLOW}Step 1: Verifying contract on Etherscan...${NC}"
echo ""

forge verify-contract \
    --chain-id 11155111 \
    --num-of-optimizations 200 \
    --compiler-version 0.8.33 \
    --etherscan-api-key $SEPOLIA_ETHERSCAN_API_KEY \
    --constructor-args $(cast abi-encode "constructor(address,address)" 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14) \
    $DEFISWAP_ADDRESS \
    src/DefiSwap.sol:DefiSwap || echo "Contract may already be verified"

echo ""

# Step 2: Display contract configuration
echo -e "${YELLOW}Step 2: Displaying contract configuration...${NC}"
echo ""

export DEFISWAP_ADDRESS=$DEFISWAP_ADDRESS

forge script script/VerifyDefiSwap.s.sol:VerifyDefiSwap \
    --rpc-url $SEPOLIA_RPC_URL \
    -vvv

echo ""
echo -e "${GREEN}=== Verification Complete ===${NC}"
echo ""
echo "Etherscan: https://sepolia.etherscan.io/address/$DEFISWAP_ADDRESS"
echo ""
