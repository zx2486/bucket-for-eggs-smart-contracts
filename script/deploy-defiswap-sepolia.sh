#!/bin/bash

# DefiSwap Sepolia Deployment Script
# This script deploys the DefiSwap contract to Sepolia testnet

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== DefiSwap Sepolia Deployment ===${NC}"
echo ""

# Check if .env file exists
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    echo "Please create a .env file with the following variables:"
    echo "  PRIVATE_KEY=your_private_key"
    echo "  SEPOLIA_RPC_URL=your_sepolia_rpc_url"
    echo "  ETHERSCAN_API_KEY=your_etherscan_api_key"
    exit 1
fi

# Load environment variables
source .env

# Check required environment variables
if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not set in .env${NC}"
    exit 1
fi

if [ -z "$SEPOLIA_RPC_URL" ]; then
    echo -e "${RED}Error: SEPOLIA_RPC_URL not set in .env${NC}"
    exit 1
fi

if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo -e "${YELLOW}Warning: ETHERSCAN_API_KEY not set. Contract verification will be skipped.${NC}"
fi

# Set network
export NETWORK=sepolia

echo -e "${YELLOW}Network: Sepolia Testnet${NC}"
echo -e "${YELLOW}RPC URL: $SEPOLIA_RPC_URL${NC}"
echo ""

# Confirm deployment
read -p "Do you want to proceed with deployment? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo -e "${RED}Deployment cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Starting deployment...${NC}"
echo ""

# Deploy contract
forge script script/DeployDefiSwap.s.sol:DeployDefiSwap \
    --rpc-url $SEPOLIA_RPC_URL \
    --broadcast \
    --verify \
    -vvvv

# Check if deployment was successful
if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}=== Deployment Successful! ===${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Save the deployed contract address from the output above"
    echo "2. Verify the contract on Etherscan (if not auto-verified)"
    echo "3. Test the contract with small deposits first"
    echo "4. Configure additional DEXs if needed using configureDEX()"
    echo ""
    echo "Important notes:"
    echo "- Only Uniswap V3 is enabled by default on Sepolia"
    echo "- Curve is not available on Sepolia testnet"
    echo "- Uniswap V4 is disabled pending deployment"
    echo "- Fluid DEX needs manual configuration"
    echo ""
    echo "Contract addresses used:"
    echo "- USDT: 0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0"
    echo "- WETH: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14"
    echo "- Uniswap V3 Router: 0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E"
    echo ""
else
    echo ""
    echo -e "${RED}=== Deployment Failed! ===${NC}"
    echo "Please check the error messages above"
    exit 1
fi
