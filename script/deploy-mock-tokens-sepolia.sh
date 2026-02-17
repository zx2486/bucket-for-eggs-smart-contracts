#!/bin/bash

set -e

# Load environment variables
source .env

# Validate required variables
if [ -z "$PRIVATE_KEY" ]; then
    echo "Error: PRIVATE_KEY not set in .env"
    exit 1
fi

if [ -z "$SEPOLIA_RPC_URL" ]; then
    echo "Error: SEPOLIA_RPC_URL not set in .env"
    exit 1
fi

# Display deployment information
echo "========================================="
echo "Deploying Mock Tokens to Sepolia"
echo "========================================="
echo "Network: Sepolia"
echo "RPC URL: $SEPOLIA_RPC_URL"
echo "Deployer: $(cast wallet address --private-key $PRIVATE_KEY)"
echo ""
echo "This will deploy:"
echo "  1. MockERC20Upgradeable implementation"
echo "  2. MockERC20Factory contract"
echo "  3. USDC minimal proxy (EIP-1167)"
echo "  4. DAI minimal proxy (EIP-1167)"
echo "  5. WBTC minimal proxy (EIP-1167)"
echo ""
echo "Press Enter to continue or Ctrl+C to cancel..."
read

# Deploy contracts
forge script script/DeployMockTokens.s.sol \
    --rpc-url $SEPOLIA_RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $SEPOLIA_ETHERSCAN_API_KEY \
    -vvv

echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo "Check deployment artifacts in broadcast/DeployMockTokens.s.sol/11155111/ directory"
echo "Update configs/sepolia.json with the deployed addresses"
echo ""
