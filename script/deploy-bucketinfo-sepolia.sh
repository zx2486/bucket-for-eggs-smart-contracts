#!/bin/bash

# Deploy BucketInfo to Ethereum Sepolia Testnet
# Usage: ./script/deploy-bucketinfo-sepolia.sh

source .env

echo "Deploying BucketInfo to Sepolia Testnet..."
echo "Deployer address: $(cast wallet address --private-key $PRIVATE_KEY)"

forge script script/DeployBucketInfo.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv

echo "Deployment complete!"
echo "Check deployment artifacts in broadcast/ directory"
