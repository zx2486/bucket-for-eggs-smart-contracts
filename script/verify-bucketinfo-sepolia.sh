#!/bin/bash

set -e

# Load environment variables
source .env

# Get BucketInfo address from deployment artifacts or user input
if [ -z "$1" ]; then
    # Try to read from latest deployment broadcast
    BROADCAST_FILE="broadcast/DeployBucketInfo.s.sol/11155111/run-latest.json"
    
    if [ -f "$BROADCAST_FILE" ]; then
        echo "Reading BucketInfo address from latest deployment..."
        BUCKETINFO_ADDRESS=$(jq -r '.transactions[] | select(.contractName == "BucketInfo") | .contractAddress' "$BROADCAST_FILE" | head -n 1)
    else
        echo "Error: No deployment found. Please provide BucketInfo contract address as argument."
        echo "Usage: ./script/verify-bucketinfo-sepolia.sh <BUCKETINFO_ADDRESS>"
        exit 1
    fi
else
    BUCKETINFO_ADDRESS=$1
fi

# Validate address
if [ -z "$BUCKETINFO_ADDRESS" ] || [ "$BUCKETINFO_ADDRESS" = "null" ]; then
    echo "Error: Could not determine BucketInfo address"
    echo "Usage: ./script/verify-bucketinfo-sepolia.sh <BUCKETINFO_ADDRESS>"
    exit 1
fi

echo "========================================="
echo "BucketInfo Contract Verification"
echo "========================================="
echo "Network: Sepolia"
echo "Contract Address: $BUCKETINFO_ADDRESS"
echo ""

# Step 1: Verify contract on Etherscan
echo "Step 1: Verifying contract on Etherscan..."
echo ""

forge verify-contract \
    --chain-id 11155111 \
    --num-of-optimizations 200 \
    --watch \
    --compiler-version 0.8.33 \
    --etherscan-api-key $SEPOLIA_ETHERSCAN_API_KEY \
    $BUCKETINFO_ADDRESS \
    src/BucketInfo.sol:BucketInfo || echo "Contract may already be verified"

echo ""
echo "Step 2: Displaying contract information..."
echo ""

# Step 2: Display contract information
export BUCKETINFO_ADDRESS=$BUCKETINFO_ADDRESS

forge script script/VerifyBucketInfo.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    -vvv

echo ""
echo "========================================="
echo "Verification Complete!"
echo "========================================="
echo "Contract Address: $BUCKETINFO_ADDRESS"
echo "Etherscan: https://sepolia.etherscan.io/address/$BUCKETINFO_ADDRESS"
echo ""
