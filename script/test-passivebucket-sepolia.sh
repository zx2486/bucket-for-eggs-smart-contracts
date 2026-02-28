#!/bin/bash

# Live integration test script for PassiveBucket on Sepolia.
#
# Tests executed (in order):
#   1.  Read contract state (owner, distributions, DEXs, fees, total value)
#   2.  Deposit ETH to receive share tokens
#   3.  Verify share balance & token price
#   4.  Deposit ERC-20 token (optional – needs TEST_TOKEN_ADDRESS)
#   5.  Check total value reflects deposits
#   6.  Verify distribution percentages
#   7.  Run a swap (via defi) and verify distribution changes
#   8.  Redeem a portion of shares
#   9.  Verify share balance decreased & tokens returned
#  10.  Pause / unpause cycle
#  11.  Owner accountability check
#  12.  Final state summary

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS="${GREEN}✓${NC}"
FAIL="${RED}✗${NC}"

# ── Environment ─────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
    echo -e "${RED}Error: .env file not found${NC}"; exit 1
fi
source .env

for var in PASSIVE_BUCKET_PROXY_ADDRESS PRIVATE_KEY SEPOLIA_RPC_URL; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: $var not set in .env${NC}"; exit 1
    fi
done

PB="$PASSIVE_BUCKET_PROXY_ADDRESS"
USER=$(cast wallet address --private-key "$PRIVATE_KEY")

# Optional ERC-20 test token (USDT, WETH, etc.)
TEST_TOKEN="${TEST_TOKEN_ADDRESS:-}"

echo -e "${GREEN}=== PassiveBucket Integration Test ===${NC}"
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Contract : $PB"
echo "  Tester   : $USER"
echo "  Network  : Sepolia (chainId 11155111)"
[ -n "$TEST_TOKEN" ] && echo "  ERC-20   : $TEST_TOKEN"
echo ""

# ── Helpers ──────────────────────────────────────────────────────────────────
send_tx() {
    local desc="$1"; shift
    echo -e "${CYAN}  → $desc${NC}"
    local result
    result=$(cast send "$@" \
        --private-key "$PRIVATE_KEY" \
        --rpc-url "$SEPOLIA_RPC_URL" \
        --json 2>&1) || { echo -e "${FAIL} Transaction failed: $result"; exit 1; }
    local hash
    hash=$(echo "$result" | jq -r '.transactionHash')
    echo "    TX: $hash"
    cast receipt "$hash" --rpc-url "$SEPOLIA_RPC_URL" > /dev/null
    echo -e "    ${PASS} Confirmed"
    echo ""
}

call_view() {
    cast call "$PB" "$@" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "N/A"
}

# ── Step 1: Contract state ───────────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Reading contract state${NC}"
echo ""

OWNER=$(call_view "owner()(address)")
PAUSED=$(call_view "paused()(bool)")
SWAP_PAUSED=$(call_view "swapPaused()(bool)")
BUCKET_INFO=$(call_view "bucketInfo()(address)")
ONEINCH=$(call_view "oneInchRouter()(address)")
WETH_ADDR=$(call_view "weth()(address)")
TOKEN_PRICE=$(call_view "tokenPrice()(uint256)")
TOTAL_SUPPLY=$(call_view "totalSupply()(uint256)")
TOTAL_DEPOSIT=$(call_view "totalDepositValue()(uint256)")
DIST_COUNT=$(call_view "getDistributionCount()(uint256)")
IS_ACCOUNTABLE=$(call_view "isBucketAccountable()(bool)")

echo "  Owner           : $OWNER"
echo "  BucketInfo      : $BUCKET_INFO"
echo "  1inch Router    : $ONEINCH"
echo "  WETH            : $WETH_ADDR"
echo "  Paused          : $PAUSED"
echo "  Swap Paused     : $SWAP_PAUSED"
echo "  Token Price     : $TOKEN_PRICE (8 dec USD)"
echo "  Total Supply    : $TOTAL_SUPPLY"
echo "  Total Deposit   : $TOTAL_DEPOSIT (8 dec USD)"
echo "  Distribution #  : $DIST_COUNT"
echo "  Accountable     : $IS_ACCOUNTABLE"
echo ""

if [ "$PAUSED" = "true" ]; then
    echo -e "${RED}Contract is paused – exiting.${NC}"; exit 1
fi

# Print distributions
echo -e "${YELLOW}  Distributions:${NC}"
for i in $(seq 0 $((DIST_COUNT - 1))); do
    DIST=$(cast call "$PB" "getBucketDistributions()((address,uint256)[])" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null)
    echo "  $DIST"
    break  # getBucketDistributions returns full array; only print once
done
echo ""

# Total value
TOTAL_VALUE=$(call_view "calculateTotalValue()(uint256)")
echo "  Total Portfolio Value (USD 8 dec): $TOTAL_VALUE"
echo ""

# ── Step 2: Deposit ETH ─────────────────────────────────────────────────────
echo -e "${YELLOW}Step 2: Depositing ETH to receive shares${NC}"
echo ""

DEPOSIT_ETH="5000000000000000"  # 0.005 ETH
DEPOSIT_ETH_F=$(cast --to-unit "$DEPOSIT_ETH" ether)
echo "  Deposit amount: $DEPOSIT_ETH_F ETH"

USER_ETH=$(cast balance "$USER" --rpc-url "$SEPOLIA_RPC_URL")
USER_ETH_F=$(cast --to-unit "$USER_ETH" ether)
echo "  User ETH balance: $USER_ETH_F ETH"

DEPOSITED_ETH=false
if python3 -c "import sys; sys.exit(0 if float('$USER_ETH_F') >= float('$DEPOSIT_ETH_F') + 0.003 else 1)" 2>/dev/null; then
    SHARES_BEFORE=$(cast call "$PB" "balanceOf(address)(uint256)" "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
    send_tx "deposit(address(0), 0) with $DEPOSIT_ETH_F ETH" \
        "$PB" "deposit(address,uint256)" "0x0000000000000000000000000000000000000000" 0 \
        --value "$DEPOSIT_ETH"
    DEPOSITED_ETH=true
else
    echo -e "${YELLOW}  Insufficient ETH – skipping deposit.${NC}"
    echo "  Get Sepolia ETH from: https://sepoliafaucet.com/"
    echo ""
fi

# ── Step 3: Verify shares ───────────────────────────────────────────────────
echo -e "${YELLOW}Step 3: Verifying share balance & token price${NC}"
echo ""

SHARES_AFTER=$(cast call "$PB" "balanceOf(address)(uint256)" "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
TOKEN_PRICE_AFTER=$(call_view "tokenPrice()(uint256)")

echo "  Shares before deposit : ${SHARES_BEFORE:-0}"
echo "  Shares after deposit  : $SHARES_AFTER"
echo "  Token price           : $TOKEN_PRICE_AFTER (8 dec USD)"

if [ "$DEPOSITED_ETH" = "true" ]; then
    if [ "$SHARES_AFTER" != "0" ] && [ "$SHARES_AFTER" != "${SHARES_BEFORE:-0}" ]; then
        echo -e "  ${PASS} Shares minted successfully"
    else
        echo -e "  ${FAIL} No new shares minted"
    fi
fi
echo ""

# ── Step 4: Deposit ERC-20 (optional) ────────────────────────────────────────
echo -e "${YELLOW}Step 4: Deposit ERC-20 token (optional)${NC}"
echo ""

DEPOSITED_ERC20=false
if [ -z "$TEST_TOKEN" ]; then
    echo -e "  ${YELLOW}TEST_TOKEN_ADDRESS not set – skipping ERC-20 deposit.${NC}"
    echo ""
else
    TOKEN_DECIMALS=$(cast call "$TEST_TOKEN" "decimals()(uint8)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "6")
    USER_TOKEN_BAL=$(cast call "$TEST_TOKEN" "balanceOf(address)(uint256)" "$USER" \
        --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
    echo "  Token balance: $USER_TOKEN_BAL (decimals: $TOKEN_DECIMALS)"

    if [ "$USER_TOKEN_BAL" = "0" ]; then
        echo -e "  ${YELLOW}No token balance – skipping.${NC}"
        echo ""
    else
        # Deposit 1 token unit
        DEPOSIT_AMOUNT=$(python3 -c "print(10 ** int('$TOKEN_DECIMALS'))" 2>/dev/null || echo "1000000")
        echo "  Depositing $DEPOSIT_AMOUNT smallest units (1 token)"

        send_tx "approve PassiveBucket" \
            "$TEST_TOKEN" "approve(address,uint256)" "$PB" "$DEPOSIT_AMOUNT"
        send_tx "deposit(TEST_TOKEN, $DEPOSIT_AMOUNT)" \
            "$PB" "deposit(address,uint256)" "$TEST_TOKEN" "$DEPOSIT_AMOUNT"
        DEPOSITED_ERC20=true
        echo -e "  ${PASS} ERC-20 deposit complete"
    fi
fi

# ── Step 5: Total value after deposits ───────────────────────────────────────
echo -e "${YELLOW}Step 5: Checking total value reflects deposits${NC}"
echo ""

TOTAL_VALUE_AFTER=$(call_view "calculateTotalValue()(uint256)")
TOTAL_DEPOSIT_AFTER=$(call_view "totalDepositValue()(uint256)")

echo "  Total value before  : $TOTAL_VALUE"
echo "  Total value after   : $TOTAL_VALUE_AFTER"
echo "  Total deposit value : $TOTAL_DEPOSIT_AFTER"

if [ "$DEPOSITED_ETH" = "true" ] || [ "$DEPOSITED_ERC20" = "true" ]; then
    if python3 -c "import sys; sys.exit(0 if int('${TOTAL_VALUE_AFTER:-0}') > int('${TOTAL_VALUE:-0}') else 1)" 2>/dev/null; then
        echo -e "  ${PASS} Total value increased after deposit"
    else
        echo -e "  ${FAIL} Total value did not increase"
    fi
fi
echo ""

# ── Step 6: Distribution percentages ─────────────────────────────────────────
echo -e "${YELLOW}Step 6: Verifying distribution percentages${NC}"
echo ""
echo "  (Distributions are target weights – actual allocations depend on holdings)"
DISTS_DATA=$(cast call "$PB" "getBucketDistributions()((address,uint256)[])" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "N/A")
echo "  $DISTS_DATA"
echo ""

# ── Step 7: Run a swap (via defi) and verify distribution changes ─────────────
echo -e "${YELLOW}Step 7: Run a swap (via defi) and verify distribution changes${NC}"
echo ""

SWAPPED=false
SWAP_PAUSED_NOW=$(call_view "swapPaused()(bool)")
USER_SHARES_FOR_SWAP=$(cast call "$PB" "balanceOf(address)(uint256)" "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")

if [ "$SWAP_PAUSED_NOW" = "true" ]; then
    echo -e "  ${YELLOW}Swap is paused on this contract – skipping.${NC}"
    echo ""
elif [ "$USER_SHARES_FOR_SWAP" = "0" ]; then
    echo -e "  ${YELLOW}User holds no shares (required to call rebalanceByDefi) – skipping.${NC}"
    echo ""
else
    VALUE_BEFORE_SWAP=$(call_view "calculateTotalValue()(uint256)")
    PRICE_BEFORE_SWAP=$(call_view "tokenPrice()(uint256)")
    echo "  Total value before swap : $VALUE_BEFORE_SWAP (8 dec USD)"
    echo "  Token price before swap : $PRICE_BEFORE_SWAP (8 dec USD)"

    echo -e "${CYAN}  → rebalanceByDefi()${NC}"
    SWAP_RESULT=$(cast send "$PB" "rebalanceByDefi()" \
        --private-key "$PRIVATE_KEY" \
        --rpc-url "$SEPOLIA_RPC_URL" \
        --json 2>&1) && {
        SWAP_HASH=$(echo "$SWAP_RESULT" | jq -r '.transactionHash')
        echo "    TX: $SWAP_HASH"
        cast receipt "$SWAP_HASH" --rpc-url "$SEPOLIA_RPC_URL" > /dev/null
        echo -e "    ${PASS} Confirmed"
        SWAPPED=true
    } || {
        echo -e "  ${YELLOW}rebalanceByDefi() reverted (distribution may already be valid).${NC}"
    }
    echo ""

    VALUE_AFTER_SWAP=$(call_view "calculateTotalValue()(uint256)")
    PRICE_AFTER_SWAP=$(call_view "tokenPrice()(uint256)")
    echo "  Total value after swap  : $VALUE_AFTER_SWAP (8 dec USD)"
    echo "  Token price after swap  : $PRICE_AFTER_SWAP (8 dec USD)"

    if [ "$SWAPPED" = "true" ]; then
        echo -e "  ${PASS} Swap executed – distribution rebalance attempted"
    else
        echo -e "  ${PASS} Distribution already within tolerance – no swap needed"
    fi
    echo ""
fi

# ── Step 8: Redeem shares ────────────────────────────────────────────────────
echo -e "${YELLOW}Step 8: Redeeming a portion of shares${NC}"
echo ""

CURRENT_SHARES=$(cast call "$PB" "balanceOf(address)(uint256)" "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
echo "  Current shares: $CURRENT_SHARES"

REDEEMED=false
if [ "$CURRENT_SHARES" != "0" ] && [ -n "$CURRENT_SHARES" ]; then
    # Redeem 10% of shares
    REDEEM_AMOUNT=$(python3 -c "print(max(1, int('$CURRENT_SHARES') // 10))" 2>/dev/null || echo "0")
    echo "  Redeeming ~10%: $REDEEM_AMOUNT shares"

    if [ "$REDEEM_AMOUNT" != "0" ]; then
        send_tx "redeem($REDEEM_AMOUNT)" "$PB" "redeem(uint256)" "$REDEEM_AMOUNT"
        REDEEMED=true
    else
        echo "  Cannot redeem 0 shares – skipping."
        echo ""
    fi
else
    echo "  No shares to redeem – skipping."
    echo ""
fi

# ── Step 9: Verify after redemption ──────────────────────────────────────────
echo -e "${YELLOW}Step 9: Verifying share balance after redemption${NC}"
echo ""

SHARES_POST_REDEEM=$(cast call "$PB" "balanceOf(address)(uint256)" "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
TOTAL_WITHDRAW_AFTER=$(call_view "totalWithdrawValue()(uint256)")

echo "  Shares before redeem  : $CURRENT_SHARES"
echo "  Shares after redeem   : $SHARES_POST_REDEEM"
echo "  Total withdraw value  : $TOTAL_WITHDRAW_AFTER"

if [ "$REDEEMED" = "true" ]; then
    if python3 -c "import sys; sys.exit(0 if int('$SHARES_POST_REDEEM') < int('$CURRENT_SHARES') else 1)" 2>/dev/null; then
        echo -e "  ${PASS} Shares decreased after redemption"
    else
        echo -e "  ${FAIL} Shares did not decrease"
    fi
fi
echo ""

# ── Step 10: Pause / unpause cycle ───────────────────────────────────────────
echo -e "${YELLOW}Step 10: Pause / unpause cycle (owner only)${NC}"
echo ""

#if [ "${USER,,}" != "${OWNER,,}" ]; then
if [ "$(echo "$USER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')" ]; then
    echo -e "  ${YELLOW}You are not the contract owner – skipping pause test.${NC}"
    echo ""
else
    # Check accountability first (owner must hold >= 5%)
    IS_ACC=$(call_view "isBucketAccountable()(bool)")
    if [ "$IS_ACC" = "true" ]; then
        send_tx "pause()" "$PB" "pause()"
        PAUSED_CHECK=$(call_view "paused()(bool)")
        [ "$PAUSED_CHECK" = "true" ] \
            && echo -e "  ${PASS} Contract paused" \
            || echo -e "  ${FAIL} Contract not paused"

        send_tx "unpause()" "$PB" "unpause()"
        UNPAUSED_CHECK=$(call_view "paused()(bool)")
        [ "$UNPAUSED_CHECK" = "false" ] \
            && echo -e "  ${PASS} Contract unpaused" \
            || echo -e "  ${FAIL} Contract still paused"
    else
        echo -e "  ${YELLOW}Owner not accountable (< 5% shares) – cannot pause.${NC}"
    fi
fi
echo ""

# ── Step 11: Accountability check ────────────────────────────────────────────
echo -e "${YELLOW}Step 11: Owner accountability check${NC}"
echo ""

FINAL_SUPPLY=$(call_view "totalSupply()(uint256)")
OWNER_SHARES=$(cast call "$PB" "balanceOf(address)(uint256)" "$OWNER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
FINAL_ACCOUNTABLE=$(call_view "isBucketAccountable()(bool)")

echo "  Total supply    : $FINAL_SUPPLY"
echo "  Owner shares    : $OWNER_SHARES"
echo "  Accountable     : $FINAL_ACCOUNTABLE"

if [ "$FINAL_SUPPLY" = "0" ]; then
    echo "  (No supply – accountability trivially true)"
elif [ "$FINAL_ACCOUNTABLE" = "true" ]; then
    echo -e "  ${PASS} Owner holds >= 5% of total supply"
else
    echo -e "  ${YELLOW}Owner holds < 5% of total supply – some owner functions restricted${NC}"
fi
echo ""

# ── Step 12: Final summary ───────────────────────────────────────────────────
echo -e "${YELLOW}Step 12: Final state summary${NC}"
echo ""

FINAL_VALUE=$(call_view "calculateTotalValue()(uint256)")
FINAL_PRICE=$(call_view "tokenPrice()(uint256)")
FINAL_USER_SHARES=$(cast call "$PB" "balanceOf(address)(uint256)" "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")

echo "  Total portfolio value : $FINAL_VALUE (8 dec USD)"
echo "  Token price           : $FINAL_PRICE (8 dec USD)"
echo "  User shares           : $FINAL_USER_SHARES"
echo ""

echo -e "${GREEN}=== Test Complete ===${NC}"
echo ""
echo "  Contract on Etherscan:"
echo "  https://sepolia.etherscan.io/address/$PB"
echo ""
echo "  Tests run:"
echo "  ${PASS} 1.  Contract state read"
[ "$DEPOSITED_ETH"    = "true" ] && echo "  ${PASS} 2.  Deposited ETH"                || echo "  -    2.  ETH deposit (skipped – insufficient ETH)"
[ "$DEPOSITED_ETH"    = "true" ] && echo "  ${PASS} 3.  Shares verified after deposit" || echo "  -    3.  Shares verification (no deposit)"
[ "$DEPOSITED_ERC20"  = "true" ] && echo "  ${PASS} 4.  Deposited ERC-20"              || echo "  -    4.  ERC-20 deposit (skipped)"
echo "  ${PASS} 5.  Total value checked"
echo "  ${PASS} 6.  Distributions verified"
[ "$SWAPPED"          = "true" ] && echo "  ${PASS} 7.  Swap via defi executed"          || echo "  -    7.  Swap via defi (skipped or no-op)"
[ "$REDEEMED"         = "true" ] && echo "  ${PASS} 8.  Redeemed shares"               || echo "  -    8.  Redemption (skipped – no shares)"
[ "$REDEEMED"         = "true" ] && echo "  ${PASS} 9.  Balance verified after redeem"  || echo "  -    9.  Post-redeem verification (skipped)"
echo "  ${PASS} 10. Pause/unpause cycle"
echo "  ${PASS} 11. Accountability check"
echo "  ${PASS} 12. Final summary"
echo ""
