#!/bin/bash

# Complete PassiveBucket Deployment Script for Sepolia
# Deploys implementation + UUPS proxy and configures DEXs

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== PassiveBucket Sepolia Deployment (via Factory) ===${NC}"
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

if [ -z "$BUCKET_INFO_ADDRESS" ]; then
    echo -e "${RED}Error: BUCKET_INFO_ADDRESS not set in .env${NC}"
    echo "Deploy BucketInfo first and set BUCKET_INFO_ADDRESS in .env"
    exit 1
fi

DEPLOYER=$(cast wallet address --private-key $PRIVATE_KEY)

echo -e "${YELLOW}Deployment Configuration:${NC}"
echo "Deployer: $DEPLOYER"
echo "Network: Sepolia"
echo "BucketInfo: $BUCKET_INFO_ADDRESS"
echo ""

# Check deployer balance
BALANCE=$(cast balance $DEPLOYER --rpc-url $SEPOLIA_RPC_URL)
BALANCE_ETH=$(cast --to-unit $BALANCE ether)
echo "Deployer Balance: $BALANCE_ETH ETH"
echo ""

# Deploy
echo -e "${GREEN}Deploying PassiveBucket...${NC}"

forge script script/DeployPassiveBucketSepolia.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvv

# Extract the new proxy and implementation address from the broadcast output
PROXY_ADDRESS=$(grep "Deployed to:" broadcast/DeployPassiveBucketSepolia.s.sol.txt | awk '{print $3}')
IMPLEMENTATION_ADDRESS=$(grep "Implementation:" broadcast/DeployPassiveBucketSepolia.s.sol.txt | awk '{print $2}')
echo "New PassiveBucket Proxy Address: $PROXY_ADDRESS"
echo "New PassiveBucket Implementation Address: $IMPLEMENTATION_ADDRESS"
echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo "Check the broadcast folder for deployment details."
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Add PASSIVE_BUCKET_PROXY_ADDRESS and PASSIVE_BUCKET_FACTORY_ADDRESS to .env"
echo "2. Run verification: ./script/verify-passivebucket-sepolia.sh"
echo "3. Run tests: ./script/test-passivebucket-sepolia.sh"
echo "4. Configure additional DEXs as needed"
echo "5. Owner should deposit initial funds for accountability"