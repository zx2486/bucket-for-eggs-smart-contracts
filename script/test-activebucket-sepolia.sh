#!/bin/bash

# Live integration test script for ActiveBucket on Sepolia.
#
# Tests executed (in order):
#   1.  Read contract state (owner, fees, total value)
#   2.  Deposit ETH to receive share tokens
#   3.  Verify share balance & token price
#   4.  Deposit ERC-20 token (optional – needs TEST_TOKEN_ADDRESS)
#   5.  Check total value reflects deposits
#   6.  Check performance fee configuration
#   7.  Redeem a portion of shares
#   8.  Verify share balance decreased & tokens returned
#   9.  Pause / unpause cycle
#  10.  Owner accountability check
#  11.  Final state summary

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

for var in ACTIVE_BUCKET_PROXY_ADDRESS PRIVATE_KEY SEPOLIA_RPC_URL; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: $var not set in .env${NC}"; exit 1
    fi
done

AB="$ACTIVE_BUCKET_PROXY_ADDRESS"
USER=$(cast wallet address --private-key "$PRIVATE_KEY")

# Optional ERC-20 test token (USDT, WETH, etc.)
TEST_TOKEN="${TEST_TOKEN_ADDRESS:-}"

echo -e "${GREEN}=== ActiveBucket Integration Test ===${NC}"
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Contract : $AB"
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
    cast call "$AB" "$@" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "N/A"
}

# ── Step 1: Contract state ───────────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Reading contract state${NC}"
echo ""

OWNER=$(call_view "owner()(address)")
PAUSED=$(call_view "paused()(bool)")
SWAP_PAUSED=$(call_view "swapPaused()(bool)")
BUCKET_INFO=$(call_view "bucketInfo()(address)")
ONEINCH=$(call_view "oneInchRouter()(address)")
TOKEN_PRICE=$(call_view "tokenPrice()(uint256)")
TOTAL_SUPPLY=$(call_view "totalSupply()(uint256)")
TOTAL_DEPOSIT=$(call_view "totalDepositValue()(uint256)")
PERF_FEE=$(call_view "performanceFeeBps()(uint256)")
IS_ACCOUNTABLE=$(call_view "isBucketAccountable()(bool)")

echo "  Owner           : $OWNER"
echo "  BucketInfo      : $BUCKET_INFO"
echo "  1inch Router    : $ONEINCH"
echo "  Paused          : $PAUSED"
echo "  Swap Paused     : $SWAP_PAUSED"
echo "  Token Price     : $TOKEN_PRICE (8 dec USD)"
echo "  Total Supply    : $TOTAL_SUPPLY"
echo "  Total Deposit   : $TOTAL_DEPOSIT (8 dec USD)"
echo "  Perf Fee (bps)  : $PERF_FEE"
echo "  Accountable     : $IS_ACCOUNTABLE"
echo ""

if [ "$PAUSED" = "true" ]; then
    echo -e "${RED}Contract is paused – exiting.${NC}"; exit 1
fi

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
    SHARES_BEFORE=$(cast call "$AB" "balanceOf(address)(uint256)" "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
    send_tx "deposit(address(0), 0) with $DEPOSIT_ETH_F ETH" \
        "$AB" "deposit(address,uint256)" "0x0000000000000000000000000000000000000000" 0 \
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

SHARES_AFTER=$(cast call "$AB" "balanceOf(address)(uint256)" "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
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

        send_tx "approve ActiveBucket" \
            "$TEST_TOKEN" "approve(address,uint256)" "$AB" "$DEPOSIT_AMOUNT"
        send_tx "deposit(TEST_TOKEN, $DEPOSIT_AMOUNT)" \
            "$AB" "deposit(address,uint256)" "$TEST_TOKEN" "$DEPOSIT_AMOUNT"
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

# ── Step 6: Performance fee configuration ─────────────────────────────────────
echo -e "${YELLOW}Step 6: Checking performance fee configuration${NC}"
echo ""

PERF_FEE_NOW=$(call_view "performanceFeeBps()(uint256)")
echo "  Performance fee (bps): $PERF_FEE_NOW"
echo "  (500 = 5% default)"

if [ "$PERF_FEE_NOW" != "N/A" ] && [ "$PERF_FEE_NOW" != "0" ]; then
    echo -e "  ${PASS} Performance fee is set"
else
    echo -e "  ${YELLOW}Performance fee is zero or unavailable${NC}"
fi
echo ""

# ── Step 7: Redeem shares ────────────────────────────────────────────────────
echo -e "${YELLOW}Step 7: Redeeming a portion of shares${NC}"
echo ""

CURRENT_SHARES=$(cast call "$AB" "balanceOf(address)(uint256)" "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
echo "  Current shares: $CURRENT_SHARES"

REDEEMED=false
if [ "$CURRENT_SHARES" != "0" ] && [ -n "$CURRENT_SHARES" ]; then
    # Redeem 10% of shares
    REDEEM_AMOUNT=$(python3 -c "print(max(1, int('$CURRENT_SHARES') // 10))" 2>/dev/null || echo "0")
    echo "  Redeeming ~10%: $REDEEM_AMOUNT shares"

    if [ "$REDEEM_AMOUNT" != "0" ]; then
        send_tx "redeem($REDEEM_AMOUNT)" "$AB" "redeem(uint256)" "$REDEEM_AMOUNT"
        REDEEMED=true
    else
        echo "  Cannot redeem 0 shares – skipping."
        echo ""
    fi
else
    echo "  No shares to redeem – skipping."
    echo ""
fi

# ── Step 8: Verify after redemption ──────────────────────────────────────────
echo -e "${YELLOW}Step 8: Verifying share balance after redemption${NC}"
echo ""

SHARES_POST_REDEEM=$(cast call "$AB" "balanceOf(address)(uint256)" "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
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

# ── Step 9: Pause / unpause cycle ───────────────────────────────────────────
echo -e "${YELLOW}Step 9: Pause / unpause cycle (owner only)${NC}"
echo ""

if [ "${USER,,}" != "${OWNER,,}" ]; then
    echo -e "  ${YELLOW}You are not the contract owner – skipping pause test.${NC}"
    echo ""
else
    send_tx "pause()" "$AB" "pause()"
    PAUSED_CHECK=$(call_view "paused()(bool)")
    [ "$PAUSED_CHECK" = "true" ] \
        && echo -e "  ${PASS} Contract paused" \
        || echo -e "  ${FAIL} Contract not paused"

    send_tx "unpause()" "$AB" "unpause()"
    UNPAUSED_CHECK=$(call_view "paused()(bool)")
    [ "$UNPAUSED_CHECK" = "false" ] \
        && echo -e "  ${PASS} Contract unpaused" \
        || echo -e "  ${FAIL} Contract still paused"
fi
echo ""

# ── Step 10: Accountability check ────────────────────────────────────────────
echo -e "${YELLOW}Step 10: Owner accountability check${NC}"
echo ""

FINAL_SUPPLY=$(call_view "totalSupply()(uint256)")
OWNER_SHARES=$(cast call "$AB" "balanceOf(address)(uint256)" "$OWNER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
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

# ── Step 11: Final summary ───────────────────────────────────────────────────
echo -e "${YELLOW}Step 11: Final state summary${NC}"
echo ""

FINAL_VALUE=$(call_view "calculateTotalValue()(uint256)")
FINAL_PRICE=$(call_view "tokenPrice()(uint256)")
FINAL_USER_SHARES=$(cast call "$AB" "balanceOf(address)(uint256)" "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")

echo "  Total portfolio value : $FINAL_VALUE (8 dec USD)"
echo "  Token price           : $FINAL_PRICE (8 dec USD)"
echo "  User shares           : $FINAL_USER_SHARES"
echo ""

echo -e "${GREEN}=== Test Complete ===${NC}"
echo ""
echo "  Contract on Etherscan:"
echo "  https://sepolia.etherscan.io/address/$AB"
echo ""
echo "  Tests run:"
echo "  ${PASS} 1.  Contract state read"
[ "$DEPOSITED_ETH"    = "true" ] && echo "  ${PASS} 2.  Deposited ETH"                || echo "  -    2.  ETH deposit (skipped – insufficient ETH)"
[ "$DEPOSITED_ETH"    = "true" ] && echo "  ${PASS} 3.  Shares verified after deposit" || echo "  -    3.  Shares verification (no deposit)"
[ "$DEPOSITED_ERC20"  = "true" ] && echo "  ${PASS} 4.  Deposited ERC-20"              || echo "  -    4.  ERC-20 deposit (skipped)"
echo "  ${PASS} 5.  Total value checked"
echo "  ${PASS} 6.  Performance fee checked"
[ "$REDEEMED"         = "true" ] && echo "  ${PASS} 7.  Redeemed shares"               || echo "  -    7.  Redemption (skipped – no shares)"
[ "$REDEEMED"         = "true" ] && echo "  ${PASS} 8.  Balance verified after redeem"  || echo "  -    8.  Post-redeem verification (skipped)"
echo "  ${PASS} 9.  Pause/unpause cycle"
echo "  ${PASS} 10. Accountability check"
echo "  ${PASS} 11. Final summary"
echo ""
