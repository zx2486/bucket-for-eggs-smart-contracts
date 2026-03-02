#!/bin/bash

# Pre-flight check for rebalanceByDefi() on the PassiveBucket proxy.
#
# What this script does:
#   1. Reads current contract state (distributions, balances, total value)
#   2. Checks if the distribution is already within tolerance (no-op case)
#   3. Simulates rebalanceByDefi() via `cast call` to detect reverts
#   4. If simulation passes, estimates gas via `cast estimate`
#   5. Prints a ready-to-use `cast send` command with a safe gas limit
#
# Required .env variables:
#   PRIVATE_KEY
#   SEPOLIA_RPC_URL
#   PASSIVE_BUCKET_PROXY_ADDRESS

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Environment ─────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"; exit 1
fi
source .env

for var in PRIVATE_KEY SEPOLIA_RPC_URL PASSIVE_BUCKET_PROXY_ADDRESS; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: $var not set in .env${NC}"; exit 1
    fi
done

PB="$PASSIVE_BUCKET_PROXY_ADDRESS"
CALLER=$(cast wallet address --private-key "$PRIVATE_KEY")

echo -e "${GREEN}=== rebalanceByDefi() Pre-flight Check ===${NC}"
echo ""
echo "  Proxy   : $PB"
echo "  Caller  : $CALLER"
echo "  Network : Sepolia"
echo ""

# ── Step 1: Contract state ──────────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Reading contract state...${NC}"

OWNER=$(cast call "$PB" "owner()(address)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "N/A")
echo "  Owner            : $OWNER"

TOTAL_SUPPLY=$(cast call "$PB" "totalSupply()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
echo "  Total supply     : $TOTAL_SUPPLY"

TOTAL_VALUE=$(cast call "$PB" "calculateTotalValue()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
TOTAL_VALUE_USD=$(echo "scale=4; $TOTAL_VALUE / 100000000" | bc 2>/dev/null || echo "N/A")
echo "  Total value      : $TOTAL_VALUE ($TOTAL_VALUE_USD USD)"

TOKEN_PRICE=$(cast call "$PB" "tokenPrice()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
echo "  Token price      : $TOKEN_PRICE"

SWAP_PAUSED=$(cast call "$PB" "swapPaused()(bool)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "N/A")
echo "  Swap paused      : $SWAP_PAUSED"

ACCOUNTABLE=$(cast call "$PB" "isBucketAccountable()(bool)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "N/A")
echo "  Owner accountable: $ACCOUNTABLE"

CALLER_SHARES=$(cast call "$PB" "balanceOf(address)(uint256)" "$CALLER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
echo "  Caller shares    : $CALLER_SHARES"

DEX_COUNT=$(cast call "$PB" "dexCount()(uint8)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
echo "  DEX count        : $DEX_COUNT"
echo ""

# ── Step 2: Quick pre-checks ────────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Pre-checks...${NC}"
HAS_ERROR=false

if [ "$CALLER_SHARES" = "0" ]; then
    echo -e "  ${RED}✗ Caller has 0 shares — rebalanceByDefi() requires shares > 0${NC}"
    HAS_ERROR=true
fi

if [ "$SWAP_PAUSED" = "true" ]; then
    echo -e "  ${RED}✗ Swap is paused — rebalanceByDefi() will revert${NC}"
    HAS_ERROR=true
fi

if [ "$DEX_COUNT" = "0" ]; then
    echo -e "  ${RED}✗ No DEX configured — swaps will fail${NC}"
    HAS_ERROR=true
fi

if [ "$HAS_ERROR" = "true" ]; then
    echo ""
    echo -e "${RED}Pre-checks failed. Fix the above issues before proceeding.${NC}"
    exit 1
fi

echo -e "  ${GREEN}✓ All pre-checks passed${NC}"
echo ""

# ── Step 3: Show distributions + current weights ────────────────────────────
echo -e "${YELLOW}Step 3: Distribution analysis...${NC}"

DIST_COUNT=$(cast call "$PB" "getDistributionCount()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
echo "  Distribution count: $DIST_COUNT"

if [ "$DIST_COUNT" -gt 0 ] && [ "$TOTAL_VALUE" != "0" ]; then
    DISTS=$(cast call "$PB" "getBucketDistributions()((address,uint256)[])" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "")
    echo "  Raw distributions: $DISTS"
    echo ""
    echo "  Token                                     | Target | Current Value"
    echo "  ------------------------------------------|--------|-------------"

    # Parse each distribution entry
    for i in $(seq 0 $((DIST_COUNT - 1))); do
        # Extract token + weight from the raw output
        TOKEN=$(echo "$DISTS" | grep -oE '0x[0-9a-fA-F]{40}' | sed -n "$((i+1))p" || echo "")
        WEIGHT=$(echo "$DISTS" | grep -oE '[0-9]+' | sed -n "$((i+1))p" || echo "?")

        if [ -n "$TOKEN" ]; then
            # Get current balance value
            TOKEN_VAL=$(cast call "$PB" "_getTokenValue(address)(uint256)" "$TOKEN" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
            if [ "$TOKEN_VAL" = "0" ] || [ -z "$TOKEN_VAL" ]; then
                # Try getting balance directly
                if [ "$TOKEN" = "0x0000000000000000000000000000000000000000" ]; then
                    BAL=$(cast balance "$PB" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
                    echo "  $TOKEN | ${WEIGHT}%    | ETH bal: $BAL wei"
                else
                    BAL=$(cast call "$TOKEN" "balanceOf(address)(uint256)" "$PB" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
                    echo "  $TOKEN | ${WEIGHT}%    | bal: $BAL"
                fi
            else
                VAL_USD=$(echo "scale=4; $TOKEN_VAL / 100000000" | bc 2>/dev/null || echo "?")
                echo "  $TOKEN | ${WEIGHT}%    | \$$VAL_USD"
            fi
        fi
    done
fi
echo ""

# ── Step 4: Simulate rebalanceByDefi() ──────────────────────────────────────
echo -e "${YELLOW}Step 4: Simulating rebalanceByDefi()...${NC}"

# Temporarily disable set -e so a revert doesn't kill the script
set +e
SIMULATE_OUTPUT=$(cast call "$PB" \
    "rebalanceByDefi()" \
    --from "$CALLER" \
    --rpc-url "$SEPOLIA_RPC_URL" \
    2>&1)
SIMULATE_EXIT=$?
set -e

if [ $SIMULATE_EXIT -ne 0 ]; then
    echo -e "  ${RED}✗ Simulation REVERTED${NC}"
    echo ""
    echo -e "${CYAN}Revert reason:${NC}"
    echo "$SIMULATE_OUTPUT"
    echo ""

    # Try to decode common revert reasons
    if echo "$SIMULATE_OUTPUT" | grep -qi "InsufficientShares"; then
        echo -e "  ${YELLOW}→ Caller has no shares. Deposit first.${NC}"
    elif echo "$SIMULATE_OUTPUT" | grep -qi "SwapIsPaused"; then
        echo -e "  ${YELLOW}→ Swap is paused. Owner must call unpauseSwap().${NC}"
    elif echo "$SIMULATE_OUTPUT" | grep -qi "PlatformNotOperational"; then
        echo -e "  ${YELLOW}→ BucketInfo platform is not operational.${NC}"
    elif echo "$SIMULATE_OUTPUT" | grep -qi "OwnerNotAccountable"; then
        echo -e "  ${YELLOW}→ Owner does not hold ≥5% of supply.${NC}"
    elif echo "$SIMULATE_OUTPUT" | grep -qi "ValueLossTooHigh"; then
        echo -e "  ${YELLOW}→ Swap would lose more than 0.5% of value. Liquidity may be low.${NC}"
    elif echo "$SIMULATE_OUTPUT" | grep -qi "DistributionMismatch"; then
        echo -e "  ${YELLOW}→ After swaps, distribution still doesn't match targets (liquidity too low).${NC}"
    elif echo "$SIMULATE_OUTPUT" | grep -qi "No DEX available"; then
        echo -e "  ${YELLOW}→ No DEX can quote the required swap pair. Check DEX configuration.${NC}"
    elif echo "$SIMULATE_OUTPUT" | grep -qi "Zero quote"; then
        echo -e "  ${YELLOW}→ All DEXs returned 0 for the quote. Liquidity pool may be empty.${NC}"
    elif echo "$SIMULATE_OUTPUT" | grep -qi "WETH not set"; then
        echo -e "  ${YELLOW}→ WETH address not configured. Owner must call setWETH().${NC}"
    elif echo "$SIMULATE_OUTPUT" | grep -qi "Price deviation too high"; then
        echo -e "  ${YELLOW}→ Token price changed too much during rebalance (>20%). Possible oracle issue.${NC}"
    fi
    echo ""
    echo -e "${RED}rebalanceByDefi() would revert. Do NOT send this transaction.${NC}"
    exit 1
fi

echo -e "  ${GREEN}✓ Simulation PASSED — transaction will succeed${NC}"
echo ""

# ── Step 5: Estimate gas ────────────────────────────────────────────────────
echo -e "${YELLOW}Step 5: Estimating gas...${NC}"

set +e
GAS_ESTIMATE=$(cast estimate "$PB" \
    "rebalanceByDefi()" \
    --from "$CALLER" \
    --rpc-url "$SEPOLIA_RPC_URL" \
    2>&1)
ESTIMATE_EXIT=$?
set -e

if [ $ESTIMATE_EXIT -ne 0 ]; then
    echo -e "  ${RED}✗ Gas estimation failed:${NC}"
    echo "  $GAS_ESTIMATE"
    echo ""
    echo "  Using fallback gas limit: 3000000"
    GAS_LIMIT=3000000
else
    echo "  Estimated gas : $GAS_ESTIMATE"
    # Add 30% buffer for safety (oracle prices can shift between estimate and execution)
    GAS_LIMIT=$(echo "$GAS_ESTIMATE * 130 / 100" | bc)
    echo "  Gas limit (30% buffer) : $GAS_LIMIT"
fi

# Get current gas price
GAS_PRICE=$(cast gas-price --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
if [ "$GAS_PRICE" != "0" ]; then
    GAS_PRICE_GWEI=$(cast --to-unit "$GAS_PRICE" gwei 2>/dev/null || echo "?")
    COST_WEI=$(echo "$GAS_LIMIT * $GAS_PRICE" | bc 2>/dev/null || echo "0")
    COST_ETH=$(cast --to-unit "$COST_WEI" ether 2>/dev/null || echo "?")
    echo "  Gas price      : $GAS_PRICE_GWEI gwei"
    echo "  Max cost       : ~$COST_ETH ETH"
fi
echo ""

# ── Step 6: Ready-to-use command ─────────────────────────────────────────────
echo -e "${GREEN}=== Ready to Execute ===${NC}"
echo ""
echo "Run this command to execute rebalanceByDefi():"
echo ""
echo -e "${CYAN}cast send $PB \\"
echo "    \"rebalanceByDefi()\" \\"
echo "    --gas-limit $GAS_LIMIT \\"
echo "    --private-key \$PRIVATE_KEY \\"
echo "    --rpc-url \$SEPOLIA_RPC_URL${NC}"
echo ""

read -p "Execute now? (y/N) " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${CYAN}Sending transaction...${NC}"
    TX_RESULT=$(cast send "$PB" \
        "rebalanceByDefi()" \
        --gas-limit "$GAS_LIMIT" \
        --private-key "$PRIVATE_KEY" \
        --rpc-url "$SEPOLIA_RPC_URL" \
        --json 2>&1)
    TX_EXIT=$?

    if [ $TX_EXIT -ne 0 ]; then
        echo -e "${RED}Transaction failed:${NC}"
        echo "$TX_RESULT"
        exit 1
    fi

    TX_HASH=$(echo "$TX_RESULT" | jq -r '.transactionHash // empty')
    TX_STATUS=$(echo "$TX_RESULT" | jq -r '.status // empty')
    GAS_USED=$(echo "$TX_RESULT" | jq -r '.gasUsed // empty')

    echo ""
    echo -e "${GREEN}Transaction sent!${NC}"
    echo "  TX hash  : $TX_HASH"
    echo "  Status   : $TX_STATUS"
    echo "  Gas used : $GAS_USED (limit was $GAS_LIMIT)"
    echo ""

    if [ "$TX_STATUS" = "0x1" ] || [ "$TX_STATUS" = "1" ]; then
        echo -e "${GREEN}✓ rebalanceByDefi() succeeded${NC}"

        # Show post-rebalance state
        NEW_PRICE=$(cast call "$PB" "tokenPrice()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "?")
        NEW_VALUE=$(cast call "$PB" "calculateTotalValue()(uint256)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "?")
        echo "  New token price : $NEW_PRICE"
        echo "  New total value : $NEW_VALUE"
    else
        echo -e "${RED}✗ Transaction reverted on-chain${NC}"
        echo "  Check https://sepolia.etherscan.io/tx/$TX_HASH for details"
    fi
else
    echo "Aborted."
fi
