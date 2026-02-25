#!/bin/bash

# Complete ActiveBucket Deployment Script for Sepolia (via ActiveBucketFactory)

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== ActiveBucket Sepolia Deployment (via Factory) ===${NC}"
echo ""

if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

source .env

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

BALANCE=$(cast balance $DEPLOYER --rpc-url $SEPOLIA_RPC_URL)
BALANCE_ETH=$(cast --to-unit $BALANCE ether)
echo "Deployer Balance: $BALANCE_ETH ETH"
echo ""

echo -e "${GREEN}Deploying ActiveBucket (implementation + factory + proxy)...${NC}"

forge script script/DeployActiveBucketSepolia.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvv

# Extract the new proxy and implementation address from the broadcast output
PROXY_ADDRESS=$(grep "Deployed to:" broadcast/DeployActiveBucketSepolia.s.sol.txt | awk '{print $3}')
IMPLEMENTATION_ADDRESS=$(grep "Implementation:" broadcast/DeployActiveBucketSepolia.s.sol.txt | awk '{print $2}')
echo "New ActiveBucket Proxy Address: $PROXY_ADDRESS"
echo "New ActiveBucket Implementation Address: $IMPLEMENTATION_ADDRESS"
echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo "Check the broadcast folder for deployment details."
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Add ACTIVE_BUCKET_PROXY_ADDRESS and ACTIVE_BUCKET_FACTORY_ADDRESS to .env"
echo "2. Run verification: ./script/verify-activebucket-sepolia.sh"
echo "3. Run tests: ./script/test-activebucket-sepolia.sh"
echo "4. Configure additional DEXs as needed"
echo "5. Owner should deposit initial funds for accountability"