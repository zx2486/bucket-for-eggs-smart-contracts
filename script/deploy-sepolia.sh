#!/bin/bash

# Deploy to Sepolia Testnet
# Usage: ./script/deploy-sepolia.sh

source .env

echo "Deploying to Sepolia Testnet..."
echo "Deployer address: $(cast wallet address --private-key $PRIVATE_KEY)"

forge script script/DeployBucketToken.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv

echo "Deployment complete!"
echo "Check deployment artifacts in broadcast/ directory"
