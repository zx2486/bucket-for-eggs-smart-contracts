#!/bin/bash

# Universal deployment script for BucketInfo contract
# Usage: ./script/deploy.sh <network>
# Example: ./script/deploy.sh sepolia

set -e

# Load environment variables
source .env

# Get network from argument or default to sepolia
NETWORK=${1:-sepolia}

# Validate network
if [ ! -f "config/${NETWORK}.json" ]; then
    echo "Error: Configuration file config/${NETWORK}.json not found"
    echo "Available networks:"
    ls config/*.json 2>/dev/null | sed 's/config\///' | sed 's/.json//' || echo "No configurations found"
    exit 1
fi

# Set network-specific variables
RPC_URL=$SEPOLIA_RPC_URL
ETHERSCAN_API_KEY=$SEPOLIA_ETHERSCAN_API_KEY

# Validate RPC URL
if [ -z "$RPC_URL" ]; then
    echo "Error: RPC_URL not set for network '$NETWORK'"
    exit 1
fi

# Display deployment information
echo "========================================="
echo "Deploying BucketInfo to $NETWORK"
echo "========================================="
echo "Network: $NETWORK"
echo "RPC URL: $RPC_URL"
echo "Deployer: $(cast wallet address --private-key $PRIVATE_KEY)"
echo "Config: config/${NETWORK}.json"
echo ""
echo "Press Enter to continue or Ctrl+C to cancel..."
read

# Export network for Solidity script
export NETWORK=$NETWORK

# Deploy contract
forge script script/DeployBucketInfo.s.sol \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv

echo ""
echo "========================================="
echo "Deployment complete!"
echo "========================================="
echo "Network: $NETWORK"
echo "Check deployment artifacts in broadcast/ directory"
echo ""