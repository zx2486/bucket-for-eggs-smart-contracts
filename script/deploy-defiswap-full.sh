#!/bin/bash

# Complete DefiSwap Deployment Script for Sepolia
# Deploys contract and configures Uniswap V3

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== DefiSwap Sepolia Deployment ===${NC}"
echo ""

# Load environment variables
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

source .env

# Validate environment variables
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not set in .env${NC}"
    exit 1
fi

if [ -z "$SEPOLIA_RPC_URL" ]; then
    echo -e "${RED}Error: SEPOLIA_RPC_URL not set in .env${NC}"
    exit 1
fi

# Get deployer address
DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

echo -e "${YELLOW}Deployment Configuration:${NC}"
echo "Deployer: $DEPLOYER"
echo "Network: Sepolia"
echo "RPC URL: $SEPOLIA_RPC_URL"
echo ""

# Check deployer balance
BALANCE=$(cast balance $DEPLOYER --rpc-url $SEPOLIA_RPC_URL)
BALANCE_ETH=$(cast --to-unit $BALANCE ether)
echo "Deployer Balance: $BALANCE_ETH ETH"

if (( $(echo "$BALANCE_ETH < 0.1" | bc -l) )); then
    echo -e "${RED}Warning: Low balance. You need at least 0.1 ETH for deployment.${NC}"
    echo "Get Sepolia ETH from: https://sepoliafaucet.com/"
    read -p "Continue anyway? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        exit 0
    fi
fi

echo ""
echo -e "${YELLOW}Press Enter to deploy or Ctrl+C to cancel...${NC}"
read

# Deploy contract
echo -e "${GREEN}Deploying DefiSwap contract...${NC}"
echo ""

forge script script/DeployDefiSwapSepolia.s.sol:DeployDefiSwapSepolia \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $SEPOLIA_ETHERSCAN_API_KEY \
    -vvv

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}=== Deployment Successful! ===${NC}"
    echo ""
    
    # Extract deployed address from broadcast
    BROADCAST_FILE="broadcast/DeployDefiSwapSepolia.s.sol/11155111/run-latest.json"
    
    if [ -f "$BROADCAST_FILE" ]; then
        DEFISWAP_ADDRESS=$(jq -r '.transactions[] | select(.contractName == "DefiSwap") | .contractAddress' "$BROADCAST_FILE" | head -n 1)
        
        if [ -n "$DEFISWAP_ADDRESS" ] && [ "$DEFISWAP_ADDRESS" != "null" ]; then
            echo "Contract Address: $DEFISWAP_ADDRESS"
            echo ""
            echo "Add to your .env file:"
            echo "DEFISWAP_ADDRESS=$DEFISWAP_ADDRESS"
            echo ""
            echo "View on Etherscan:"
            echo "https://sepolia.etherscan.io/address/$DEFISWAP_ADDRESS"
            echo ""
        fi
    fi
    
    echo -e "${YELLOW}Next Steps:${NC}"
    echo "1. Add DEFISWAP_ADDRESS to .env"
    echo "2. Run verification: ./script/verify-defiswap-sepolia.sh"
    echo "3. Run tests: ./script/test-defiswap-sepolia.sh"
    echo ""
else
    echo ""
    echo -e "${RED}=== Deployment Failed ===${NC}"
    echo "Check the error messages above"
    exit 1
fi
