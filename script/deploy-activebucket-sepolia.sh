#!/bin/bash

# Complete ActiveBucket Deployment Script for Sepolia (via ActiveBucketFactory)

set -e
cd "$(dirname "$0")/.."

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

set -a
source .env
set +a

if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not set in .env${NC}"
    exit 1
fi

if [ -z "$SEPOLIA_RPC_URL" ]; then
    echo -e "${RED}Error: SEPOLIA_RPC_URL not set in .env${NC}"
    exit 1
fi

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")

echo -e "${YELLOW}Deployment Configuration:${NC}"
echo "Deployer: $DEPLOYER"
echo "Network: Sepolia"
echo "Config: configs/sepolia.json"
echo ""

BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$SEPOLIA_RPC_URL")
BALANCE_ETH=$(cast --to-unit "$BALANCE" ether)
echo "Deployer Balance: $BALANCE_ETH ETH"
echo ""

echo -e "${GREEN}Deploying ActiveBucket (implementation + factory + proxy)...${NC}"

forge script script/DeployActiveBucketSepolia.s.sol \
    --rpc-url "$SEPOLIA_RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --broadcast \
    -vvv

if [ -n "${ETHERSCAN_API_KEY:-}" ]; then
    echo "Source verification can be submitted separately with forge verify-contract after recording constructor arguments."
fi

BROADCAST_FILE="broadcast/DeployActiveBucketSepolia.s.sol/11155111/run-latest.json"
if [ ! -f "$BROADCAST_FILE" ]; then
    echo "Broadcast artifact not found: $BROADCAST_FILE" >&2
    exit 1
fi
read -r ACTIVE_BUCKET_IMPL_ADDRESS ACTIVE_BUCKET_FACTORY_ADDRESS < <(python3 - "$BROADCAST_FILE" <<'PY'
import json, sys
data=json.load(open(sys.argv[1]))
created={tx.get("contractName"): tx.get("contractAddress") for tx in data.get("transactions", []) if tx.get("transactionType")=="CREATE"}
required=("ActiveBucket", "ActiveBucketFactory")
missing=[name for name in required if not created.get(name)]
if missing:
    raise SystemExit("Missing CREATE entries: " + ", ".join(missing))
print(created["ActiveBucket"], created["ActiveBucketFactory"])
PY
)
ACTIVE_BUCKET_PROXY_ADDRESS=""
if grep -q '^ACTIVE_BUCKET_IMPL_ADDRESS=' .env; then sed -i.bak "s#^ACTIVE_BUCKET_IMPL_ADDRESS=.*#ACTIVE_BUCKET_IMPL_ADDRESS=$ACTIVE_BUCKET_IMPL_ADDRESS#" .env; else printf '\nACTIVE_BUCKET_IMPL_ADDRESS=%s\n' "$ACTIVE_BUCKET_IMPL_ADDRESS" >> .env; fi
if grep -q '^ACTIVE_BUCKET_FACTORY_ADDRESS=' .env; then sed -i.bak "s#^ACTIVE_BUCKET_FACTORY_ADDRESS=.*#ACTIVE_BUCKET_FACTORY_ADDRESS=$ACTIVE_BUCKET_FACTORY_ADDRESS#" .env; else printf 'ACTIVE_BUCKET_FACTORY_ADDRESS=%s\n' "$ACTIVE_BUCKET_FACTORY_ADDRESS" >> .env; fi
rm -f .env.bak
echo "Implementation: $ACTIVE_BUCKET_IMPL_ADDRESS"
echo "Factory: $ACTIVE_BUCKET_FACTORY_ADDRESS"
echo "Proxy address: read the ActiveBucketCreated event in $BROADCAST_FILE and set ACTIVE_BUCKET_PROXY_ADDRESS in .env"
echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo "Check the broadcast folder for deployment details."
echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Run verification: ./script/verify-activebucket-sepolia.sh"
echo "2. The owner must deposit shares before accountability-gated operations."