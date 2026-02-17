#!/bin/bash

# Complete test script for DefiSwap on Sepolia
# Tests: deposit, swap, withdraw functions

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== DefiSwap Testing Script ===${NC}"
echo ""

# Load environment variables
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"
    exit 1
fi

source .env

# Validate required variables
if [ -z "$DEFISWAP_ADDRESS" ]; then
    echo -e "${RED}Error: DEFISWAP_ADDRESS not set in .env${NC}"
    exit 1
fi

if [ -z "$PRIVATE_KEY" ]; then
    echo -e "${RED}Error: PRIVATE_KEY not set in .env${NC}"
    exit 1
fi

# Constants
USDT_ADDRESS="0xaA8E23Fb1079EA71e0a56F48a2aA51851D8433D0"
USER_ADDRESS=$(cast wallet address --private-key $PRIVATE_KEY)
TEST_AMOUNT="1000000"  # 1 USDT (6 decimals)

echo -e "${BLUE}Test Configuration:${NC}"
echo "DefiSwap: $DEFISWAP_ADDRESS"
echo "USDT: $USDT_ADDRESS"
echo "User: $USER_ADDRESS"
echo "Test Amount: $TEST_AMOUNT (1 USDT)"
echo "Network: Sepolia"
echo ""

# Function to check balances
check_balances() {
    echo -e "${YELLOW}=== Current Balances ===${NC}"
    
    # User USDT balance
    USER_USDT=$(cast call $USDT_ADDRESS "balanceOf(address)(uint256)" $USER_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
    echo "User USDT Balance: $USER_USDT (raw)"
    # Extract only the first field (number before space)
    USER_USDT=$(echo "$USER_USDT" | awk '{print $1}')
    USER_USDT=${USER_USDT:-0}
    echo "User USDT Balance: $USER_USDT (raw)"
    USER_USDT_READABLE=$(echo "scale=6; $USER_USDT / 1000000" | bc)
    echo "User USDT Balance: $USER_USDT_READABLE USDT"
    
    # Contract USDT balance
    CONTRACT_USDT=$(cast call $DEFISWAP_ADDRESS "getContractUSDTBalance()(uint256)" --rpc-url $SEPOLIA_RPC_URL)
    CONTRACT_USDT=$(echo "$CONTRACT_USDT" | awk '{print $1}')
    CONTRACT_USDT=${CONTRACT_USDT:-0}
    echo "Contract USDT Balance: $CONTRACT_USDT (raw)"
    CONTRACT_USDT_READABLE=$(echo "scale=6; $CONTRACT_USDT / 1000000" | bc)
    echo "Contract USDT Balance: $CONTRACT_USDT_READABLE USDT"
    
    # Contract ETH balance
    CONTRACT_ETH=$(cast call $DEFISWAP_ADDRESS "getContractETHBalance()(uint256)" --rpc-url $SEPOLIA_RPC_URL)
    #CONTRACT_ETH2=$(cast balance $DEFISWAP_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
    CONTRACT_ETH=$(echo "$CONTRACT_ETH" | awk '{print $1}')
    CONTRACT_ETH=${CONTRACT_ETH:-0}
    echo "Contract ETH Balance (call): $CONTRACT_ETH (raw)"
    #echo "Contract ETH Balance (balance): $CONTRACT_ETH2 (raw)"
    CONTRACT_ETH_READABLE=$(cast --to-unit $CONTRACT_ETH ether)
    echo "Contract ETH Balance: $CONTRACT_ETH_READABLE ETH"

    # User's deposited balance
    USER_BALANCE=$(cast call $DEFISWAP_ADDRESS "getUserBalance(address)(uint256)" $USER_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
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
NEEDS_SWAP=$(echo "$USER_USDT_READABLE < 2" | bc -l 2>/dev/null || echo "1")

if [ "$USER_USDT" = "0" ] || [ "$NEEDS_SWAP" = "1" ]; then
    echo "User has insufficient USDT ($USER_USDT_READABLE USDT). Swapping ETH for 20 USDT..."
    echo ""
    
    # Uniswap V3 SwapRouter02 on Sepolia
    UNISWAP_ROUTER="0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E"
    WETH_ADDRESS="0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14"
    TARGET_USDT="20000000"  # 20 USDT (6 decimals)
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
    
    echo "Executing Uniswap V3 swap: ETH → 20 USDT"
    echo "Router: $UNISWAP_ROUTER"
    echo "Max ETH input: 0.02 ETH"
    echo ""
    
    # Execute exactOutputSingle swap
    # Parameters: (tokenIn, tokenOut, fee, recipient, amountOut, amountInMaximum, sqrtPriceLimitX96)
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
    echo -e "${GREEN}✓ Swap confirmed - 20 USDT received${NC}"
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
echo -e "${BLUE}Step 3: Approving USDT for DefiSwap${NC}"
echo "Approving 20 USDT (20000000)..."
echo ""

APPROVE_TX=$(cast send $USDT_ADDRESS \
    "approve(address,uint256)" \
    $DEFISWAP_ADDRESS \
    20000000 \
    --private-key $PRIVATE_KEY \
    --rpc-url $SEPOLIA_RPC_URL \
    --json)

APPROVE_HASH=$(echo $APPROVE_TX | jq -r '.transactionHash')
echo "Approval TX: $APPROVE_HASH"
echo "Waiting for confirmation..."
cast receipt $APPROVE_HASH --rpc-url $SEPOLIA_RPC_URL > /dev/null
echo -e "${GREEN}✓ Approval confirmed${NC}"
echo ""

# Check allowance
ALLOWANCE=$(cast call $USDT_ADDRESS "allowance(address,address)(uint256)" $USER_ADDRESS $DEFISWAP_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
ALLOWANCE=$(echo "$ALLOWANCE" | awk '{print $1}')
ALLOWANCE=${ALLOWANCE:-0}
ALLOWANCE_READABLE=$(echo "scale=6; $ALLOWANCE / 1000000" | bc)
echo "Current Allowance: $ALLOWANCE_READABLE USDT"
echo ""

# Test 2: Deposit USDT
echo -e "${BLUE}Step 4: Depositing USDT${NC}"
echo "Depositing $TEST_AMOUNT (1 USDT)..."
echo ""

DEPOSIT_TX=$(cast send $DEFISWAP_ADDRESS \
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

# Test 3: Get swap quote
echo -e "${BLUE}Step 5: Getting swap quote${NC}"
echo ""

# Calculate 50% of contract balance
CONTRACT_BALANCE=$(cast call $DEFISWAP_ADDRESS "getContractUSDTBalance()(uint256)" --rpc-url $SEPOLIA_RPC_URL)
CONTRACT_BALANCE=$(echo "$CONTRACT_BALANCE" | awk '{print $1}')
CONTRACT_BALANCE=${CONTRACT_BALANCE:-0}
SWAP_AMOUNT=$((CONTRACT_BALANCE / 2))
SWAP_AMOUNT_READABLE=$(echo "scale=6; $SWAP_AMOUNT / 1000000" | bc)
echo "Will swap: $SWAP_AMOUNT_READABLE USDT (50% of contract balance)"
echo ""

# Test 4: Execute swap (owner only)
echo -e "${BLUE}Step 6: Executing swap${NC}"
echo "Note: This must be called by the contract owner"
echo ""

# Pre-swap diagnostics
echo -e "${YELLOW}Pre-swap diagnostics:${NC}"
echo "Checking DEX configurations..."
echo ""

# Check Uniswap V3 config
V3_CONFIG=$(cast call $DEFISWAP_ADDRESS "getDEXConfig(uint8)((address,address,uint24,bool))" 0 --rpc-url $SEPOLIA_RPC_URL)
echo "Uniswap V3 Config: $V3_CONFIG"
V3_ENABLED=$(echo $V3_CONFIG | awk '{print $4}')
echo "Uniswap V3 Enabled: $V3_ENABLED"

if [ "$V3_ENABLED" = "true)" ]; then
    V3_ROUTER=$(echo $V3_CONFIG | awk '{print $1}')
    V3_QUOTER=$(echo $V3_CONFIG | awk '{print $2}')
    V3_FEE=$(echo $V3_CONFIG | awk '{print $3}')
    echo "  Router: $V3_ROUTER"
    echo "  Quoter: $V3_QUOTER"
    echo "  Fee: $V3_FEE"
    echo ""
    
    # Try to get a quote
    echo "Testing quote for 5 USDT..."
    QUOTE_RESULT=$(cast call $DEFISWAP_ADDRESS "getBestQuote(uint256)(uint8,uint256)" 5000000 --rpc-url $SEPOLIA_RPC_URL 2>&1 || echo "QUOTE_FAILED")
    echo "Quote result: $QUOTE_RESULT"
    if [[ "$QUOTE_RESULT" == *"QUOTE_FAILED"* ]] || [[ "$QUOTE_RESULT" == *"revert"* ]]; then
        echo -e "${RED}❌ Quote failed - there may be liquidity issues${NC}"
        echo "Error: $QUOTE_RESULT"
        echo ""
        echo -e "${YELLOW}This is common on Sepolia due to low liquidity.${NC}"
        echo "Options:"
        echo "1. Try with a smaller amount"
        echo "2. Test on mainnet fork instead"
        echo "3. Continue anyway (swap may fail)"
        echo ""
        read -p "Continue with swap attempt? (yes/no): " continue_swap
        if [ "$continue_swap" != "yes" ]; then
            echo "Skipping swap test"
            exit 0
        fi
    else
        echo -e "${GREEN}✓ Quote successful${NC}"
        BEST_DEX=$(echo $QUOTE_RESULT | awk '{print $1}')
        BEST_QUOTE=$(echo $QUOTE_RESULT | awk '{print $2}')
        echo "Best DEX: $BEST_DEX"
        echo "Quote: $BEST_QUOTE wei"
        echo ""
    fi
else
    echo -e "${RED}❌ No DEX enabled!${NC}"
    echo "Please configure at least one DEX before swapping"
    exit 1
fi

read -p "Are you the contract owner? Deploy from this address? (yes/no): " is_owner
if [ "$is_owner" = "yes" ]; then
    echo "Executing swap..."
    
    SWAP_TX=$(cast send $DEFISWAP_ADDRESS \
        "swap()" \
        --private-key $PRIVATE_KEY \
        --rpc-url $SEPOLIA_RPC_URL \
        --json)
    
    SWAP_HASH=$(echo $SWAP_TX | jq -r '.transactionHash')
    echo "Swap TX: $SWAP_HASH"
    echo "Waiting for confirmation..."
    cast receipt $SWAP_HASH --rpc-url $SEPOLIA_RPC_URL > /dev/null
    echo -e "${GREEN}✓ Swap confirmed${NC}"
    echo ""
    
    # Get swap details from receipt
    echo "Getting swap details..."
    RECEIPT=$(cast receipt $SWAP_HASH --rpc-url $SEPOLIA_RPC_URL --json)
    echo ""
    
    # Check balances after swap
    echo "Balances after swap:"
    check_balances
else
    echo -e "${YELLOW}Skipping swap (not owner)${NC}"
    echo ""
fi

# Test 5: Withdraw USDT (owner only)
echo -e "${BLUE}Step 7: Testing USDT withdrawal (owner only)${NC}"
echo ""

if [ "$is_owner" = "yes" ]; then
    WITHDRAW_AMOUNT="500000"  # 0.5 USDT
    echo "Withdrawing 0.5 USDT..."
    
    WITHDRAW_TX=$(cast send $DEFISWAP_ADDRESS \
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

# Test 6: Withdraw ETH (owner only)
echo -e "${BLUE}Step 8: Testing ETH withdrawal (owner only)${NC}"
echo ""

if [ "$is_owner" = "yes" ]; then
    # Check if contract has ETH
    CONTRACT_ETH=$(cast call $DEFISWAP_ADDRESS "getContractETHBalance()(uint256)" --rpc-url $SEPOLIA_RPC_URL)
    CONTRACT_ETH=$(echo "$CONTRACT_ETH" | awk '{print $1}')
    CONTRACT_ETH=${CONTRACT_ETH:-0}
    if [ "$CONTRACT_ETH" != "0" ]; then
        ETH_WITHDRAW_AMOUNT=$((CONTRACT_ETH / 2))
        ETH_WITHDRAW_READABLE=$(cast --to-unit $ETH_WITHDRAW_AMOUNT ether)
        echo "Withdrawing $ETH_WITHDRAW_READABLE ETH..."
        
        WITHDRAW_ETH_TX=$(cast send $DEFISWAP_ADDRESS \
            "withdrawETH(address,uint256)" \
            $USER_ADDRESS \
            $ETH_WITHDRAW_AMOUNT \
            --private-key $PRIVATE_KEY \
            --rpc-url $SEPOLIA_RPC_URL \
            --json)
        
        WITHDRAW_ETH_HASH=$(echo $WITHDRAW_ETH_TX | jq -r '.transactionHash')
        echo "ETH Withdrawal TX: $WITHDRAW_ETH_HASH"
        echo "Waiting for confirmation..."
        cast receipt $WITHDRAW_ETH_HASH --rpc-url $SEPOLIA_RPC_URL > /dev/null
        echo -e "${GREEN}✓ ETH Withdrawal confirmed${NC}"
        echo ""
    else
        echo "No ETH in contract to withdraw"
        echo ""
    fi
fi

# Final balances
echo -e "${BLUE}Step 9: Final balances${NC}"
check_balances

echo -e "${GREEN}=== Testing Complete! ===${NC}"
echo ""
echo "Summary of tests:"
echo "✓ Swapped ETH for USDT (if needed)"
echo "✓ Approved USDT"
echo "✓ Deposited USDT"
if [ "$is_owner" = "yes" ]; then
    echo "✓ Executed swap"
    echo "✓ Withdrew USDT"
    echo "✓ Withdrew ETH"
else
    echo "- Swap (owner only)"
    echo "- Withdrawals (owner only)"
fi
echo ""
echo "View transactions on Etherscan:"
echo "https://sepolia.etherscan.io/address/$DEFISWAP_ADDRESS"
echo ""
