#!/bin/bash

# DefiSwap Mainnet Deployment Script
# This script deploys the DefiSwap contract to Ethereum Mainnet
# WARNING: This deploys to MAINNET. Use with caution!

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${RED}=== DefiSwap MAINNET Deployment ===${NC}"
echo -e "${RED}WARNING: You are about to deploy to ETHEREUM MAINNET${NC}"
echo ""

# Check if .env file exists
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    echo "Please create a .env file with the following variables:"
    echo "  PRIVATE_KEY=your_private_key"
    echo "  MAINNET_RPC_URL=your_mainnet_rpc_url"
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

if [ -z "$MAINNET_RPC_URL" ]; then
    echo -e "${RED}Error: MAINNET_RPC_URL not set in .env${NC}"
    exit 1
fi

if [ -z "$ETHERSCAN_API_KEY" ]; then
    echo -e "${YELLOW}Warning: ETHERSCAN_API_KEY not set. Contract verification will be skipped.${NC}"
fi

# Set network
export NETWORK=mainnet

echo -e "${RED}Network: Ethereum Mainnet${NC}"
echo -e "${YELLOW}RPC URL: $MAINNET_RPC_URL${NC}"
echo ""

# Safety checks
echo -e "${YELLOW}=== Pre-Deployment Checklist ===${NC}"
echo "Please confirm the following:"
echo ""
echo "[ ] You have tested the contract on Sepolia testnet"
echo "[ ] You have sufficient ETH for gas fees"
echo "[ ] You have reviewed the deployment script"
echo "[ ] You have backed up your private key securely"
echo "[ ] You understand this is a MAINNET deployment"
echo "[ ] You have verified all DEX addresses are correct"
echo ""

# First confirmation
read -p "Have you completed all checklist items? (yes/no): " checklist_confirm
if [ "$checklist_confirm" != "yes" ]; then
    echo -e "${RED}Deployment cancelled - Please complete the checklist first${NC}"
    exit 0
fi

echo ""
echo -e "${YELLOW}Contract addresses that will be used:${NC}"
echo "- USDT: 0xdAC17F958D2ee523a2206206994597C13D831ec7"
echo "- WETH: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
echo "- Uniswap V3 Router: 0xE592427A0AEce92De3Edee1F18E0157C05861564"
echo "- Uniswap V3 Quoter: 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6"
echo "- Curve TriPool: 0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7"
echo ""

# Second confirmation
read -p "Are these addresses correct? (yes/no): " address_confirm
if [ "$address_confirm" != "yes" ]; then
    echo -e "${RED}Deployment cancelled - Please verify addresses${NC}"
    exit 0
fi

echo ""
echo -e "${RED}FINAL WARNING: This will deploy to MAINNET and cost real ETH${NC}"
read -p "Type 'DEPLOY TO MAINNET' to continue: " final_confirm
if [ "$final_confirm" != "DEPLOY TO MAINNET" ]; then
    echo -e "${RED}Deployment cancelled${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Starting mainnet deployment...${NC}"
echo ""

# Deploy contract
forge script script/DeployDefiSwap.s.sol:DeployDefiSwap \
    --rpc-url $MAINNET_RPC_URL \
    --broadcast \
    --verify \
    -vvvv

# Check if deployment was successful
if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}=== Deployment Successful! ===${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Save the following information securely${NC}"
    echo ""
    echo "Next steps:"
    echo "1. SAVE the deployed contract address from the output above"
    echo "2. Verify the contract on Etherscan (if not auto-verified)"
    echo "3. Transfer ownership to a multisig wallet (RECOMMENDED)"
    echo "4. Test with small amounts before announcing"
    echo "5. Monitor the contract for any issues"
    echo "6. Consider getting a security audit if not already done"
    echo ""
    echo "Configured DEXs:"
    echo "- Uniswap V3: ENABLED (0.3% fee tier)"
    echo "- Uniswap V4: DISABLED (pending V4 deployment)"
    echo "- Fluid: DISABLED (needs configuration)"
    echo "- Curve: ENABLED (TriPool)"
    echo ""
    echo "Contract addresses used:"
    echo "- USDT: 0xdAC17F958D2ee523a2206206994597C13D831ec7"
    echo "- WETH: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
    echo ""
    echo -e "${RED}SECURITY REMINDER:${NC}"
    echo "- Consider transferring ownership to a multisig"
    echo "- Monitor contract activity closely"
    echo "- Have an emergency pause plan ready"
    echo ""
else
    echo ""
    echo -e "${RED}=== Deployment Failed! ===${NC}"
    echo "Please check the error messages above"
    echo "Do NOT retry without understanding the error"
    exit 1
fi
