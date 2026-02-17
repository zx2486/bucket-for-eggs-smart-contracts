#!/bin/bash

# Complete test script for BasicSwap on Sepolia
# Tests: deposit, swap (with 1inch API), withdraw functions

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== BasicSwap Testing Script ===${NC}"
echo ""

# Load environment variables
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

source .env

# Validate required variables
if [ -z "$BASICSWAP_ADDRESS" ]; then
    echo -e "${RED}Error: BASICSWAP_ADDRESS not set in .env${NC}"
    exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not set in .env${NC}"
    exit 1
fi

# Constants
USDT_ADDRESS="0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0"
WETH_ADDRESS="0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14"
USER_ADDRESS=$(cast wallet address --private-key $PRIVATE_KEY)
TEST_AMOUNT="1000000"  # 1 USDT (6 decimals)
MAINNET_USDT="0xdAC17F958D2ee523a2206206994597C13D831ec7"
#ONEINCH_API="https://api.1inch.dev/swap/v6.0/11155111"
ONEINCH_API="https://api.1inch.dev/swap/v6.0/1" # Using mainnet API for swap data since Sepolia may not have data

echo -e "${BLUE}Test Configuration:${NC}"
echo "BasicSwap: $BASICSWAP_ADDRESS"
echo "USDT: $USDT_ADDRESS"
echo "User: $USER_ADDRESS"
echo "Test Amount: $TEST_AMOUNT (1 USDT)"
echo "Network: Sepolia (Chain ID: 11155111)"
echo ""

# Function to check balances
check_balances() {
    echo -e "${YELLOW}=== Current Balances ===${NC}"
    
    # User USDT balance
    USER_USDT=$(cast call $USDT_ADDRESS "balanceOf(address)(uint256)" $USER_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
    USER_USDT=$(echo "$USER_USDT" | awk '{print $1}')
    USER_USDT=${USER_USDT:-0}
    USER_USDT_READABLE=$(echo "scale=6; $USER_USDT / 1000000" | bc)
    echo "User USDT Balance: $USER_USDT_READABLE USDT"
    
    # Contract USDT balance
    CONTRACT_USDT=$(cast call $BASICSWAP_ADDRESS "getContractUSDTBalance()(uint256)" --rpc-url $SEPOLIA_RPC_URL)
    CONTRACT_USDT=$(echo "$CONTRACT_USDT" | awk '{print $1}')
    CONTRACT_USDT=${CONTRACT_USDT:-0}
    CONTRACT_USDT_READABLE=$(echo "scale=6; $CONTRACT_USDT / 1000000" | bc)
    echo "Contract USDT Balance: $CONTRACT_USDT_READABLE USDT"
    
    # Contract ETH balance
    CONTRACT_ETH=$(cast call $BASICSWAP_ADDRESS "getContractETHBalance()(uint256)" --rpc-url $SEPOLIA_RPC_URL)
    CONTRACT_ETH=$(echo "$CONTRACT_ETH" | awk '{print $1}')
    CONTRACT_ETH=${CONTRACT_ETH:-0}
    CONTRACT_ETH_READABLE=$(cast --to-unit $CONTRACT_ETH ether)
    echo "Contract ETH Balance: $CONTRACT_ETH_READABLE ETH"
    
    # User's deposited balance
    USER_BALANCE=$(cast call $BASICSWAP_ADDRESS "getUserBalance(address)(uint256)" $USER_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
    USER_BALANCE=$(echo "$USER_BALANCE" | awk '{print $1}')
    USER_BALANCE=${USER_BALANCE:-0}
    USER_BALANCE_READABLE=$(echo "scale=6; $USER_BALANCE / 1000000" | bc)
    echo "User's Deposited USDT: $USER_BALANCE_READABLE USDT"
    
    echo ""
}

# Initial balances
echo -e "${BLUE}Step 1: Checking initial balances${NC}"
check_balances

# Test 0: Swap ETH for USDT if needed
echo -e "${BLUE}Step 2: Getting USDT (swapping ETH if needed)${NC}"
echo ""

# Safe comparison using bc
NEEDS_SWAP=$(echo "$USER_USDT_READABLE < 5" | bc -l 2>/dev/null || echo "1")

if [ "$USER_USDT" = "0" ] || [ "$NEEDS_SWAP" = "1" ]; then
    echo "User has insufficient USDT ($USER_USDT_READABLE USDT). Swapping ETH for 10 USDT..."
    echo ""
    
    # Uniswap V3 SwapRouter02 on Sepolia
    UNISWAP_ROUTER="0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E"
    WETH_ADDRESS="0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14"
    TARGET_USDT="10000000"  # 10 USDT (6 decimals)
    MAX_ETH="20000000000000000"  # 0.02 ETH maximum input
    
    # Check user has enough ETH
    USER_ETH=$(cast balance $USER_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
    USER_ETH_READABLE=$(cast --to-unit $USER_ETH ether)
    echo "User ETH Balance: $USER_ETH_READABLE ETH"
    
    if (( $(echo "$USER_ETH_READABLE < 0.03" | bc -l) )); then
        echo -e "${RED}Error: Insufficient ETH for swap${NC}"
        echo "You need at least 0.03 ETH (0.02 for swap + gas)"
        echo "Get Sepolia ETH from: https://sepoliafaucet.com/"
        exit 1
    fi
    
    echo "Executing Uniswap V3 swap: ETH → 10 USDT"
    echo "Router: $UNISWAP_ROUTER"
    echo "Max ETH input: 0.02 ETH"
    echo ""
    
    # Execute exactOutputSingle swap
    SWAP_ETH_TX=$(cast send $UNISWAP_ROUTER \
        "exactOutputSingle((address,address,uint24,address,uint256,uint256,uint160))" \
        "($WETH_ADDRESS,$USDT_ADDRESS,3000,$USER_ADDRESS,$TARGET_USDT,$MAX_ETH,0)" \
        --value $MAX_ETH \
        --private-key $PRIVATE_KEY \
        --rpc-url $SEPOLIA_RPC_URL \
        --json)
    
    SWAP_ETH_HASH=$(echo $SWAP_ETH_TX | jq -r '.transactionHash')
    echo "Swap TX: $SWAP_ETH_HASH"
    echo "View on Etherscan: https://sepolia.etherscan.io/tx/$SWAP_ETH_HASH"
    echo "Waiting for confirmation..."
    cast receipt $SWAP_ETH_HASH --rpc-url $SEPOLIA_RPC_URL > /dev/null
    echo -e "${GREEN}✓ Swap confirmed - 10 USDT received${NC}"
    echo ""
    
    # Update USDT balance
    USER_USDT=$(cast call $USDT_ADDRESS "balanceOf(address)(uint256)" $USER_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
    USER_USDT=$(echo "$USER_USDT" | awk '{print $1}')
    USER_USDT=${USER_USDT:-0}
    USER_USDT_READABLE=$(echo "scale=6; $USER_USDT / 1000000" | bc)
    echo "Updated USDT Balance: $USER_USDT_READABLE USDT"
    echo ""
else
    echo "✓ User has sufficient USDT ($USER_USDT_READABLE USDT). Skipping ETH→USDT swap."
    echo ""
fi

# Verify user has USDT now
if [ "$USER_USDT" = "0" ]; then
    echo -e "${RED}Error: Still no USDT after swap attempt${NC}"
    echo "The swap may have failed due to low liquidity on Sepolia"
    echo "Try getting USDT manually from Uniswap interface"
    exit 1
fi

# Test 1: Approve USDT
echo -e "${BLUE}Step 3: Approving USDT for BasicSwap${NC}"
echo "Approving 10 USDT (10000000)..."
echo ""

APPROVE_TX=$(cast send $USDT_ADDRESS \
    "approve(address,uint256)" \
    $BASICSWAP_ADDRESS \
    10000000 \
    --private-key $PRIVATE_KEY \
    --rpc-url $SEPOLIA_RPC_URL \
    --json)

APPROVE_HASH=$(echo $APPROVE_TX | jq -r '.transactionHash')
echo "Approval TX: $APPROVE_HASH"
echo "Waiting for confirmation..."
cast receipt $APPROVE_HASH --rpc-url $SEPOLIA_RPC_URL > /dev/null
echo -e "${GREEN}✓ Approval confirmed${NC}"
echo ""

# Test 2: Deposit USDT
echo -e "${BLUE}Step 4: Depositing USDT${NC}"
echo "Depositing $TEST_AMOUNT (1 USDT)..."
echo ""

DEPOSIT_TX=$(cast send $BASICSWAP_ADDRESS \
    "depositUSDT(uint256)" \
    $TEST_AMOUNT \
    --private-key $PRIVATE_KEY \
    --rpc-url $SEPOLIA_RPC_URL \
    --json)

DEPOSIT_HASH=$(echo $DEPOSIT_TX | jq -r '.transactionHash')
echo "Deposit TX: $DEPOSIT_HASH"
echo "Waiting for confirmation..."
cast receipt $DEPOSIT_HASH --rpc-url $SEPOLIA_RPC_URL > /dev/null
echo -e "${GREEN}✓ Deposit confirmed${NC}"
echo ""

# Check balances after deposit
echo "Balances after deposit:"
check_balances

# Test 3: Get 1inch swap data
echo -e "${BLUE}Step 5: Getting swap data from 1inch API${NC}"
echo ""

# Calculate 50% of contract balance
CONTRACT_BALANCE=$(cast call $BASICSWAP_ADDRESS "getContractUSDTBalance()(uint256)" --rpc-url $SEPOLIA_RPC_URL)
CONTRACT_BALANCE=$(echo "$CONTRACT_BALANCE" | awk '{print $1}')
CONTRACT_BALANCE=${CONTRACT_BALANCE:-0}
SWAP_AMOUNT=$((CONTRACT_BALANCE / 2))
SWAP_AMOUNT_READABLE=$(echo "scale=6; $SWAP_AMOUNT / 1000000" | bc)
echo "Will swap: $SWAP_AMOUNT_READABLE USDT (50% of contract balance)"
echo ""

# Check if 1inch API key is available
if [ -z "$ONEINCH_APIKEY" ]; then
    echo -e "${YELLOW}Note: ONEINCH_APIKEY not set in .env file${NC}"
    echo "Get 1inch API key from https://portal.1inch.dev/"
    echo "Add to .env: ONEINCH_APIKEY=your_api_key"
    echo ""
    echo -e "${YELLOW}Skipping swap test${NC}"
    echo ""
    SKIP_SWAP=true
else
    echo "✓ 1inch API key found"
    echo ""
    
    read -p "Do you want to attempt swap via 1inch? (yes/no): " attempt_swap
    
    if [ "$attempt_swap" = "yes" ]; then
        echo ""
        echo -e "${BLUE}Fetching swap data from 1inch API...${NC}"
        echo "Amount: $SWAP_AMOUNT_READABLE USDT"
        echo "Route: USDT → ETH"
        echo ""
        
        # Call 1inch API to get swap data
        API_URL="$ONEINCH_API/swap?src=$MAINNET_USDT&dst=0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee&amount=$SWAP_AMOUNT&from=$BASICSWAP_ADDRESS&slippage=5&disableEstimate=true&allowPartialFill=false"
        SWAP_DATA_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
            -X GET "${API_URL}" \
            -H "Authorization: Bearer ${ONEINCH_APIKEY}" \
            -H "Accept: application/json" \
            2>&1)
        HTTP_STATUS=$(echo "$SWAP_DATA_RESPONSE" | grep "HTTP_STATUS" | cut -d: -f2)
        SWAP_DATA_RESPONSE=$(echo "$SWAP_DATA_RESPONSE" | sed '/HTTP_STATUS/d')
        
        echo "HTTP Status: ${HTTP_STATUS:-unknown}"
        echo ""
        # Check if API call was successful
        if echo "$SWAP_DATA_RESPONSE" | jq -e '.tx.data' > /dev/null 2>&1; then
            SWAP_DATA=$(echo "$SWAP_DATA_RESPONSE" | jq -r '.tx.data')
            EXPECTED_OUTPUT=$(echo "$SWAP_DATA_RESPONSE" | jq -r '.dstAmount')
            EXPECTED_ETH=$(cast --to-unit $EXPECTED_OUTPUT ether 2>/dev/null || echo "unknown")
            
            echo -e "${GREEN}✓ Swap data received from 1inch${NC}"
            echo "Expected output: $EXPECTED_ETH ETH"
            echo ""
            
            echo "Executing swap via BasicSwap contract..."
            SWAP_TX=$(cast send $BASICSWAP_ADDRESS \
                "swap(bytes)" \
                $SWAP_DATA \
                --private-key $PRIVATE_KEY \
                --rpc-url $SEPOLIA_RPC_URL \
                --json)
            
            SWAP_HASH=$(echo $SWAP_TX | jq -r '.transactionHash')
            echo "Swap TX: $SWAP_HASH"
            echo "View on Etherscan: https://sepolia.etherscan.io/tx/$SWAP_HASH"
            echo "Waiting for confirmation..."
            cast receipt $SWAP_HASH --rpc-url $SEPOLIA_RPC_URL > /dev/null
            echo -e "${GREEN}✓ Swap executed successfully${NC}"
            echo ""
            
            # Check balances after swap
            echo "Balances after swap:"
            check_balances
            
            SWAP_EXECUTED=true
        else
            echo -e "${RED}Error: Failed to get swap data from 1inch API${NC}"
            ERROR_MSG=$(echo "$SWAP_DATA_RESPONSE" | jq -r '.description // .error // "Unknown error"')
            echo "API Response: $ERROR_MSG"
            echo ""
            echo -e "${YELLOW}This may be due to:${NC}"
            echo "- Low liquidity on Sepolia for this swap"
            echo "- Amount too small or too large"
            echo "- API rate limits"
            echo ""
            SKIP_SWAP=true
        fi
    else
        echo -e "${YELLOW}Skipping swap test${NC}"
        echo ""
        SKIP_SWAP=true
    fi
fi

# Test 4: Withdraw USDT (owner only)
echo -e "${BLUE}Step 6: Testing USDT withdrawal (owner only)${NC}"
echo ""

read -p "Are you the contract owner? (yes/no): " is_owner
if [ "$is_owner" = "yes" ]; then
    WITHDRAW_AMOUNT="500000"  # 0.5 USDT
    echo "Withdrawing 0.5 USDT..."
    
    WITHDRAW_TX=$(cast send $BASICSWAP_ADDRESS \
        "withdrawUSDT(address,uint256)" \
        $USER_ADDRESS \
        $WITHDRAW_AMOUNT \
        --private-key $PRIVATE_KEY \
        --rpc-url $SEPOLIA_RPC_URL \
        --json)
    
    WITHDRAW_HASH=$(echo $WITHDRAW_TX | jq -r '.transactionHash')
    echo "Withdrawal TX: $WITHDRAW_HASH"
    echo "Waiting for confirmation..."
    cast receipt $WITHDRAW_HASH --rpc-url $SEPOLIA_RPC_URL > /dev/null
    echo -e "${GREEN}✓ Withdrawal confirmed${NC}"
    echo ""
fi

# Final balances
echo -e "${BLUE}Step 7: Final balances${NC}"
check_balances

echo -e "${GREEN}=== Testing Complete! ===${NC}"
echo ""
echo "Summary of tests:"
echo "✓ Swapped ETH for USDT (if needed)"
echo "✓ Approved USDT"
echo "✓ Deposited USDT"
if [ "$is_owner" = "yes" ]; then
    echo "✓ Withdrew USDT"
else
    echo "- Withdrawals (owner only)"
fi
if [ "$SWAP_EXECUTED" = "true" ]; then
    echo "✓ Executed swap via 1inch"
else
    echo "- Swap (skipped or failed)"
fi
echo ""
echo "View transactions on Etherscan:"
echo "https://sepolia.etherscan.io/address/$BASICSWAP_ADDRESS"
echo ""
