#!/bin/bash

# Verify and validate BasicSwap contract on Sepolia

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== BasicSwap Contract Verification ===${NC}"
echo ""

# Load environment variables
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

source .env

# Check if contract address is set
if [ -z "$BASICSWAP_ADDRESS" ]; then
    echo -e "${RED}Error: BASICSWAP_ADDRESS not set in .env${NC}"
    echo "Please add: BASICSWAP_ADDRESS=0x..."
    exit 1
fi

echo "Contract Address: $BASICSWAP_ADDRESS"
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
    --constructor-args $(cast abi-encode "constructor(address,address)" 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0 0x111111125421cA6dc452d289314280a0f8842A65) \
    $BASICSWAP_ADDRESS \
    src/BasicSwap.sol:BasicSwap || echo "Contract may already be verified"

echo ""

# Step 2: Display contract configuration
echo -e "${YELLOW}Step 2: Displaying contract configuration...${NC}"
echo ""

export BASICSWAP_ADDRESS=$BASICSWAP_ADDRESS

forge script script/VerifyBasicSwap.s.sol:VerifyBasicSwap \
    --rpc-url $SEPOLIA_RPC_URL \
    -vvv

echo ""
echo -e "${GREEN}=== Verification Complete ===${NC}"
echo ""
echo "Etherscan: https://sepolia.etherscan.io/address/$BASICSWAP_ADDRESS"
echo ""
