#!/bin/bash

# Deploy to Ethereum Mainnet
# Usage: ./script/deploy-mainnet.sh

source .env

echo "⚠️  WARNING: You are about to deploy to MAINNET!"
echo "Deployer address: $(cast wallet address --private-key $PRIVATE_KEY)"
read -p "Are you sure you want to continue? (yes/no) " -n 3 -r
echo
if [[ ! $REPLY =~ ^yes$ ]]
then
    echo "Deployment cancelled."
    exit 1
fi

echo "Deploying to Ethereum Mainnet..."

forge script script/DeployBucketToken.s.sol \
    --rpc-url $MAINNET_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv

echo "Deployment complete!"
echo "Check deployment artifacts in broadcast/ directory"
