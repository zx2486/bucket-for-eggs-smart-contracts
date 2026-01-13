#!/bin/bash

# Deploy to Local Anvil Node
# Usage: ./script/deploy-local.sh

echo "Deploying to Local Anvil..."

# Default Anvil account #0 private key
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

forge script script/DeployBucketToken.s.sol \
    --rpc-url http://localhost:8545 \
    --private-key $PRIVATE_KEY \
    --broadcast \
    -vvvv

echo "Deployment complete!"
echo "Contract deployed on local Anvil node"
