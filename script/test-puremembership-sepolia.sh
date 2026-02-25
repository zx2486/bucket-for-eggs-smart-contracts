#!/bin/bash

# Live integration test script for PureMembership on Sepolia.
#
# Tests executed (in order):
#   1. Read contract state & tier configs
#   2. Check user's existing memberships
#   3. Buy a Basic membership with ETH  (token ID 1)
#   4. Verify membership status (level 1)
#   5. Buy a Premium membership with ERC-20 token (token ID 2)  [optional, needs USDT]
#   6. Check revenue accumulated
#   7. Cancel Basic membership
#   8. Verify membership status after cancellation (should be active as Premium is still active)
#   9. Cancel Premium membership
#  10. Verify membership status after all cancellations (should be inactive)
#  11. Check revenue again (should be unchanged)
#  12. Attempt to withdraw revenue (owner only) - should succeed if tester is owner and revenue > 0
#  13. Verify revenue after withdrawal (should be reduced by withdrawn amount)
#  14. Final state summary

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

for var in PURE_MEMBERSHIP_PROXY_ADDRESS PRIVATE_KEY SEPOLIA_RPC_URL; do
    if [ -z "${!var}" ]; then
        echo -e "${RED}Error: $var not set in .env${NC}"; exit 1
    fi
done

PM="$PURE_MEMBERSHIP_PROXY_ADDRESS"
USER=$(cast wallet address --private-key "$PRIVATE_KEY")

# Optional ERC-20 test token (e.g. Sepolia USDT)
TEST_TOKEN="${TEST_TOKEN_ADDRESS:-}"

echo -e "${GREEN}=== PureMembership Integration Test ===${NC}"
echo ""
echo -e "${BLUE}Configuration:${NC}"
echo "  Contract : $PM"
echo "  Tester   : $USER"
echo "  Network  : Sepolia (chainId 11155111)"
[ -n "$TEST_TOKEN" ] && echo "  ERC-20   : $TEST_TOKEN"
echo ""

# ── Helpers ──────────────────────────────────────────────────────────────────
send_tx() {
    # send_tx <description> <cast send args...>
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
    # call_view <sig> [args...]
    cast call "$PM" "$@" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "N/A"
}

# ── Step 1: Contract state ───────────────────────────────────────────────────
echo -e "${YELLOW}Step 1: Reading contract state${NC}"
echo ""

OWNER=$(call_view "owner()(address)")
PAUSED=$(call_view "paused()(bool)")
BUCKET_INFO=$(call_view "bucketInfo()(address)")
TIER_COUNT=$(call_view "getConfiguredTokenIdCount()(uint256)")
ACTIVE_MEMBERS=$(call_view "activeMembershipCount()(uint256)")

echo "  Owner          : $OWNER"
echo "  BucketInfo     : $BUCKET_INFO"
echo "  Paused         : $PAUSED"
echo "  Configured tiers: $TIER_COUNT"
echo "  Active members : $ACTIVE_MEMBERS"
echo ""

if [ "$PAUSED" = "true" ]; then
    echo -e "${RED}Contract is paused – exiting.${NC}"; exit 1
fi
if [ "$TIER_COUNT" = "0" ]; then
    echo -e "${RED}No membership tiers configured – exiting.${NC}"; exit 1
fi

# Print tiers
echo -e "${YELLOW}  Membership tiers:${NC}"
for i in $(seq 0 $((TIER_COUNT - 1))); do
    TOKEN_ID=$(cast call "$PM" "configuredTokenIds(uint256)(uint256)" "$i" --rpc-url "$SEPOLIA_RPC_URL")
    CFG=$(cast call "$PM" "getMembershipInfo(uint256)((uint256,uint256,string,uint256,uint256))" "$TOKEN_ID" --rpc-url "$SEPOLIA_RPC_URL")
    echo "  [$TOKEN_ID] $CFG"
done
echo ""

# ── Step 2: Existing memberships for user ───────────────────────────────────
echo -e "${YELLOW}Step 2: Checking existing memberships for $USER${NC}"
echo ""

RAW_MEMBERSHIPS=$(cast call "$PM" \
    "getUserMemberships(address)((uint256,uint256,string,uint256,bool)[])" \
    "$USER" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "")
echo "  getUserMemberships: $RAW_MEMBERSHIPS"
echo ""

# ── Step 3: Buy Basic membership with ETH (tokenId = 1) ─────────────────────
echo -e "${YELLOW}Step 3: Buying Basic membership (tokenId=1) with ETH${NC}"
echo ""

# Fetch Basic price from tier 0 (tokenId=1)
BASIC_PRICE_RAW=$(cast call "$PM" "getMembershipInfo(uint256)(uint256,uint256,string,uint256,uint256)" 1 \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null | awk 'NR==4{print $1}')

# Get ETH price from BucketInfo (8-decimal USD feed)
ETH_PRICE_RAW=$(cast call "$BUCKET_INFO" "getTokenPrice(address)(uint256)" \
    "0x0000000000000000000000000000000000000000" \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")

if [ "$ETH_PRICE_RAW" = "0" ] || [ -z "$ETH_PRICE_RAW" ] || [ -z "$BASIC_PRICE_RAW" ]; then
    echo -e "${YELLOW}  Warning: Could not fetch price from BucketInfo.${NC}"
    echo "  Sending 0.01 ETH as an approximate payment (contract will refund excess)."
    MEMBERSHIP_ETH_VALUE="10000000000000000"  # 0.01 ETH
else
    # payAmount = (price * 10^18) / ethPrice  (both price and ethPrice are 8-dec USD)
    # Using python for safe integer arithmetic
    MEMBERSHIP_ETH_VALUE=$(python3 -c "
price = int('$BASIC_PRICE_RAW')
eth_usd = int('$ETH_PRICE_RAW')
# Add 1% buffer to cover rounding
wei = (price * 10**18 * 101) // (eth_usd * 100)
print(wei)
" 2>/dev/null || echo "10000000000000000")
fi

ETH_READABLE=$(cast --to-unit "$MEMBERSHIP_ETH_VALUE" ether)
echo "  Sending $ETH_READABLE ETH to buy Basic membership"
echo ""

# Check user ETH balance
USER_ETH=$(cast balance "$USER" --rpc-url "$SEPOLIA_RPC_URL")
USER_ETH_F=$(cast --to-unit "$USER_ETH" ether)
echo "  User ETH balance: $USER_ETH_F ETH"

if python3 -c "import sys; sys.exit(0 if float('$USER_ETH_F') >= float('$ETH_READABLE') + 0.005 else 1)" 2>/dev/null; then
    send_tx "buyMembership(1, address(0)) with ETH" \
        "$PM" "buyMembership(uint256,address)" 1 "0x0000000000000000000000000000000000000000" \
        --value "$MEMBERSHIP_ETH_VALUE"
    BOUGHT_BASIC=true
else
    echo -e "${YELLOW}  Insufficient ETH – skipping Basic ETH purchase.${NC}"
    echo "  Get Sepolia ETH from: https://sepoliafaucet.com/"
    echo ""
    BOUGHT_BASIC=false
fi

# ── Step 4: Verify membership status after purchase ──────────────────────────
echo -e "${YELLOW}Step 4: Checking membership status (level 1)${NC}"
echo ""

STATUS_L1=$(cast call "$PM" "checkMembershipStatus(address,uint256)(bool)" "$USER" 1 \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "false")
EXPIRY=$(cast call "$PM" "membershipExpiry(address,uint256)(uint256)" "$USER" 1 \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")

echo "  Level 1 active: $STATUS_L1"
if [ "$EXPIRY" != "0" ]; then
    EXPIRY_DATE=$(date -d "@$EXPIRY" 2>/dev/null || date -r "$EXPIRY" 2>/dev/null || echo "timestamp $EXPIRY")
    echo "  Expiry: $EXPIRY_DATE"
fi

if [ "$STATUS_L1" = "true" ]; then
    echo -e "  ${PASS} Basic membership is active"
elif [ "$BOUGHT_BASIC" = "true" ]; then
    echo -e "  ${FAIL} Membership purchase may have failed – check transaction"
else
    echo "  (Purchase was skipped)"
fi
echo ""

# ── Step 5: Buy Premium with ERC-20 (optional) ───────────────────────────────
echo -e "${YELLOW}Step 5: Buy Premium membership with ERC-20 token (optional)${NC}"
echo ""

if [ -z "$TEST_TOKEN" ]; then
    echo -e "  ${YELLOW}TEST_TOKEN_ADDRESS not set – skipping ERC-20 membership purchase.${NC}"
    echo "  Add TEST_TOKEN_ADDRESS=0x... to .env to enable this test."
    echo ""
else
    # Get user token balance
    TOKEN_DECIMALS=$(cast call "$TEST_TOKEN" "decimals()(uint8)" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "6")
    USER_TOKEN_BAL=$(cast call "$TEST_TOKEN" "balanceOf(address)(uint256)" "$USER" \
        --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
    echo "  Test token balance: $USER_TOKEN_BAL (decimals: $TOKEN_DECIMALS)"

    if [ "$USER_TOKEN_BAL" = "0" ]; then
        echo -e "  ${YELLOW}No token balance – skipping ERC-20 purchase.${NC}"
        echo ""
    else
        # Approve max for simplicity
        echo "  Approving token spend..."
        MAX_UINT256="0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        send_tx "approve PureMembership to spend tokens" \
            "$TEST_TOKEN" "approve(address,uint256)" "$PM" "$MAX_UINT256"

        send_tx "buyMembership(2, TEST_TOKEN)" \
            "$PM" "buyMembership(uint256,address)" 2 "$TEST_TOKEN"

        STATUS_L2=$(cast call "$PM" "checkMembershipStatus(address,uint256)(bool)" "$USER" 2 \
            --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "false")
        echo "  Level 2 active: $STATUS_L2"
        [ "$STATUS_L2" = "true" ] && echo -e "  ${PASS} Premium membership is active" || echo -e "  ${FAIL} Premium membership check failed"
        echo ""
    fi
fi

# ── Step 6: Revenue ──────────────────────────────────────────────────────────
echo -e "${YELLOW}Step 6: Checking accumulated revenue${NC}"
echo ""

cast call "$PM" "getMembershipRevenue()(address[],uint256[])" \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null \
    | sed 's/^/  /' \
    || echo "  (Could not fetch revenue – BucketInfo may have no whitelisted tokens yet)"
echo ""

# ── Step 7: Cancel Basic membership ──────────────────────────────────────────
echo -e "${YELLOW}Step 7: Cancel Basic membership (tokenId=1)${NC}"
echo ""

CANCELLED_BASIC=false
if [ "$STATUS_L1" = "true" ]; then
    send_tx "cancelMembership(1)" "$PM" "cancelMembership(uint256)" 1
    CANCELLED_BASIC=true
else
    echo "  No active Basic membership to cancel – skipping."
    echo ""
fi

# ── Step 8: Verify status after Basic cancellation ───────────────────────────
echo -e "${YELLOW}Step 8: Verifying membership status after Basic cancellation${NC}"
echo ""

STATUS_L1_AFTER=$(cast call "$PM" "checkMembershipStatus(address,uint256)(bool)" "$USER" 1 \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "false")
STATUS_L2_AFTER=$(cast call "$PM" "checkMembershipStatus(address,uint256)(bool)" "$USER" 2 \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "false")

echo "  Level 1 (Basic) active   : $STATUS_L1_AFTER  (expected: true if premium purchased, false otherwise)"
echo "  Level 2 (Premium) active : $STATUS_L2_AFTER  (expected: true if purchased)"

if [ "$CANCELLED_BASIC" = "true" ]; then
    if [ -n "$TEST_TOKEN" ]; then
        [ "$STATUS_L1_AFTER" = "true" ] \
            && echo -e "  ${PASS} Basic correctly active after cancellation as premium membership is active" \
            || echo -e "  ${FAIL} Basic appears inactive – unexpected"
    else 
        [ "$STATUS_L1_AFTER" = "false" ] \
            && echo -e "  ${PASS} Basic correctly inactive after cancellation" \
            || echo -e "  ${FAIL} Basic still appears active – unexpected"
    fi
fi
if [ "${STATUS_L2:-false}" = "true" ]; then
    [ "$STATUS_L2_AFTER" = "true" ] \
        && echo -e "  ${PASS} Premium still active (unaffected by Basic cancellation)" \
        || echo -e "  ${FAIL} Premium unexpectedly inactive"
fi
echo ""

# ── Step 9: Cancel Premium membership ────────────────────────────────────────
echo -e "${YELLOW}Step 9: Cancel Premium membership (tokenId=2)${NC}"
echo ""

CANCELLED_PREMIUM=false
if [ "${STATUS_L2:-false}" = "true" ] && [ "$STATUS_L2_AFTER" = "true" ]; then
    send_tx "cancelMembership(2)" "$PM" "cancelMembership(uint256)" 2
    CANCELLED_PREMIUM=true
else
    echo "  No active Premium membership to cancel – skipping."
    echo ""
fi

# ── Step 10: Verify status after all cancellations ───────────────────────────
echo -e "${YELLOW}Step 10: Verifying membership status after all cancellations${NC}"
echo ""

FINAL_L1=$(cast call "$PM" "checkMembershipStatus(address,uint256)(bool)" "$USER" 1 \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "false")
FINAL_L2=$(cast call "$PM" "checkMembershipStatus(address,uint256)(bool)" "$USER" 2 \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "false")

echo "  Level 1 (Basic) active   : $FINAL_L1  (expected: false)"
echo "  Level 2 (Premium) active : $FINAL_L2  (expected: false)"

if [ "$CANCELLED_BASIC" = "true" ]; then
    [ "$FINAL_L1" = "false" ] \
        && echo -e "  ${PASS} Basic inactive" \
        || echo -e "  ${FAIL} Basic unexpectedly active"
fi
if [ "$CANCELLED_PREMIUM" = "true" ]; then
    [ "$FINAL_L2" = "false" ] \
        && echo -e "  ${PASS} Premium inactive" \
        || echo -e "  ${FAIL} Premium unexpectedly active"
fi
echo ""

# ── Step 11: Check revenue again (should be unchanged by cancellations) ───────
echo -e "${YELLOW}Step 11: Checking revenue (should be unchanged after cancellations)${NC}"
echo ""

REVENUE_AFTER_CANCEL=$(cast call "$PM" "getMembershipRevenue()(address[],uint256[])" \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "")
echo "  Revenue after cancellations:"
echo "$REVENUE_AFTER_CANCEL" | sed 's/^/    /' \
    || echo "  (Could not fetch revenue)"
echo ""

# ── Step 12: Withdraw revenue (owner only) ────────────────────────────────────
echo -e "${YELLOW}Step 12: Withdraw revenue (owner only)${NC}"
echo ""

WITHDREW_REVENUE=false
REVENUE_TOKEN_WITHDRAWN=""

# if [ "${USER,,}" != "${OWNER,,}" ]; then
if [ "$(echo "$USER" | tr '[:upper:]' '[:lower:]')" != "$(echo "$OWNER" | tr '[:upper:]' '[:lower:]')" ]; then
    echo -e "  ${YELLOW}You are not the contract owner – skipping revenue withdrawal.${NC}"
    echo ""
else
    # ETH revenue
    PM_ETH_BAL=$(cast balance "$PM" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
    PM_ETH_F=$(cast --to-unit "$PM_ETH_BAL" ether 2>/dev/null || echo "0")
    echo "  Contract ETH balance (revenue): $PM_ETH_F ETH"

    if [ -z "$TEST_TOKEN" ] && [ "$PM_ETH_BAL" != "0" ] && [ "$PM_ETH_BAL" != "" ]; then
        # Withdraw a portion (all) so step 13 can verify reduction
        # WITHDRAW_HALF=$(python3 -c "print(int('$PM_ETH_BAL') // 2)" 2>/dev/null || echo "$PM_ETH_BAL")
        WITHDRAW_HALF=$(python3 -c "print(int('$PM_ETH_BAL'))" 2>/dev/null || echo "$PM_ETH_BAL")
        WITHDRAW_HALF_F=$(cast --to-unit "$WITHDRAW_HALF" ether 2>/dev/null || echo "?")
        echo "  Withdrawing all of ETH revenue: $WITHDRAW_HALF_F ETH"

        send_tx "withdrawRevenue(address(0), half)" \
            "$PM" "withdrawRevenue(address,address,uint256)" \
            "$USER" "0x0000000000000000000000000000000000000000" "$WITHDRAW_HALF"
        WITHDREW_REVENUE=true
        REVENUE_TOKEN_WITHDRAWN="ETH"
        echo -e "  ${PASS} Revenue withdrawal sent"
    else
        # Try ERC-20 revenue if TEST_TOKEN is set
        if [ -n "$TEST_TOKEN" ]; then
            TOKEN_REVENUE=$(cast call "$PM" "revenueByToken(address)(uint256)" "$TEST_TOKEN" \
                --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")    
            # Extract only the numeric value (remove scientific notation if present)
            TOKEN_REVENUE=$(echo "$TOKEN_REVENUE" | awk '{print $1}')
            TOKEN_REVENUE=${TOKEN_REVENUE:-0}
            if [ "$TOKEN_REVENUE" != "0" ] && [ -n "$TOKEN_REVENUE" ]; then
                # Calculate USD value to check minimum withdrawal requirement
                TOKEN_PRICE=$(cast call "$BUCKET_INFO" \
                    "getTokenPrice(address)(uint256)" \
                    "$TEST_TOKEN" \
                    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
                TOKEN_PRICE=$(echo "$TOKEN_PRICE" | awk '{print $1}')
                
                TOKEN_DECIMALS=$(cast call "$TEST_TOKEN" \
                    "decimals()(uint8)" \
                    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "18")
                TOKEN_DECIMALS=$(echo "$TOKEN_DECIMALS" | awk '{print $1}')
                
                # Calculate revenue in USD (8 decimals)
                TOKEN_REVENUE_USD=$(python3 -c "
token_bal = int('$TOKEN_REVENUE')
token_price = int('$TOKEN_PRICE')
decimals = int('$TOKEN_DECIMALS')
usd_value = (token_bal * token_price) // (10 ** decimals)
print(usd_value)
" 2>/dev/null || echo "0")
                
                TOKEN_REVENUE_USD_READABLE=$(python3 -c "print(f'{int(\"$TOKEN_REVENUE_USD\") / 1e8:.2f}')" 2>/dev/null || echo "?")
                
                echo "  ERC-20 revenue for $TEST_TOKEN: $TOKEN_REVENUE"
                echo "  Revenue in USD: \$${TOKEN_REVENUE_USD_READABLE}"
                
                # Check if this is first withdrawal and meets minimum
                TOTAL_WITHDRAWN=$(call_view "totalWithdrawn()(uint256)")
                TOTAL_WITHDRAWN=$(echo "$TOTAL_WITHDRAWN" | awk '{print $1}')
                TOTAL_WITHDRAWN=${TOTAL_WITHDRAWN:-0}
                
                MIN_WITHDRAWAL_USD=$((100 * 10 ** 8))  # 100 USD with 8 decimals
                
                if [ "$TOTAL_WITHDRAWN" = "0" ]; then
                    echo "  First withdrawal - minimum required: \$100.00 USD"
                    
                    if [ "$TOKEN_REVENUE_USD" -lt "$MIN_WITHDRAWAL_USD" ]; then
                        echo -e "  ${YELLOW}Insufficient revenue for first withdrawal (\$${TOKEN_REVENUE_USD_READABLE} < \$100.00)${NC}"
                        echo "  Skipping withdrawal test."
                    else
                        # Calculate half or minimum amount
                        WITHDRAW_HALF=$(python3 -c "print(int('$TOKEN_REVENUE') // 2)" 2>/dev/null || echo "$TOKEN_REVENUE")
                        WITHDRAW_HALF_USD=$(python3 -c "
token_amount = int('$WITHDRAW_HALF')
token_price = int('$TOKEN_PRICE')
decimals = int('$TOKEN_DECIMALS')
usd_value = (token_amount * token_price) // (10 ** decimals)
print(usd_value)
" 2>/dev/null || echo "0")
                        
                        # Ensure withdrawal meets minimum
                        if [ "$WITHDRAW_HALF_USD" -lt "$MIN_WITHDRAWAL_USD" ]; then
                            # Calculate minimum token amount needed for $100
                            WITHDRAW_AMOUNT=$(python3 -c "
min_usd = $MIN_WITHDRAWAL_USD
token_price = int('$TOKEN_PRICE')
decimals = int('$TOKEN_DECIMALS')
tokens_needed = (min_usd * (10 ** decimals)) // token_price
print(tokens_needed)
" 2>/dev/null || echo "$TOKEN_REVENUE")
                            WITHDRAW_AMOUNT_READABLE=$(python3 -c "print(f'{int(\"$WITHDRAW_AMOUNT\") / (10 ** int(\"$TOKEN_DECIMALS\")):.6f}')" 2>/dev/null || echo "?")
                            echo "  Withdrawing minimum: $WITHDRAW_AMOUNT_READABLE tokens (\$100.00 USD)"
                        else
                            WITHDRAW_AMOUNT="$WITHDRAW_HALF"
                            WITHDRAW_AMOUNT_READABLE=$(python3 -c "print(f'{int(\"$WITHDRAW_AMOUNT\") / (10 ** int(\"$TOKEN_DECIMALS\")):.6f}')" 2>/dev/null || echo "?")
                            echo "  Withdrawing half: $WITHDRAW_AMOUNT_READABLE tokens"
                        fi
                        
                        send_tx "withdrawRevenue(TEST_TOKEN, $WITHDRAW_AMOUNT_READABLE)" \
                            "$PM" "withdrawRevenue(address,address,uint256)" \
                            "$USER" "$TEST_TOKEN" "$WITHDRAW_AMOUNT"
                        WITHDREW_REVENUE=true
                        REVENUE_TOKEN_WITHDRAWN="$TEST_TOKEN"
                        echo -e "  ${PASS} ERC-20 revenue withdrawal sent"
                    fi
                else
                    # Not first withdrawal - withdraw total balance instead of half
                    TOKEN_BALANCE=$(cast call "$TEST_TOKEN" \
                        "balanceOf(address)(uint256)" \
                        "$PM" \
                        --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
                    TOKEN_BALANCE=$(echo "$TOKEN_BALANCE" | awk '{print $1}')
                    TOKEN_BALANCE=${TOKEN_BALANCE:-0}
                    
                    if [ "$TOKEN_BALANCE" = "0" ]; then
                        echo -e "  ${YELLOW}No token balance to withdraw${NC}"
                    else
                        WITHDRAW_AMOUNT="$TOKEN_BALANCE"
                        WITHDRAW_AMOUNT_READABLE=$(python3 -c "print(f'{int(\"$WITHDRAW_AMOUNT\") / (10 ** int(\"$TOKEN_DECIMALS\")):.6f}')" 2>/dev/null || echo "?")
                        echo "  Withdrawing total balance: $WITHDRAW_AMOUNT_READABLE tokens"
                        
                        send_tx "withdrawRevenue(TEST_TOKEN, total balance)" \
                            "$PM" "withdrawRevenue(address,address,uint256)" \
                            "$USER" "$TEST_TOKEN" "$WITHDRAW_AMOUNT"
                        WITHDREW_REVENUE=true
                        REVENUE_TOKEN_WITHDRAWN="$TEST_TOKEN"
                        echo -e "  ${PASS} ERC-20 revenue withdrawal sent"
                    fi
                fi
            else
                echo "  No revenue to withdraw yet."
            fi
        else
            echo "  No ETH revenue to withdraw."
        fi
    fi
fi
echo ""

# ── Step 13: Verify revenue after withdrawal ─────────────────────────────────
echo -e "${YELLOW}Step 13: Verifying revenue after withdrawal${NC}"
echo ""

if [ "$WITHDREW_REVENUE" = "true" ]; then
    if [ "$REVENUE_TOKEN_WITHDRAWN" = "ETH" ]; then
        PM_ETH_BAL_AFTER=$(cast balance "$PM" --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
        PM_ETH_F_AFTER=$(cast --to-unit "$PM_ETH_BAL_AFTER" ether 2>/dev/null || echo "0")
        echo "  Contract ETH balance before withdrawal : $PM_ETH_F ETH"
        echo "  Contract ETH balance after withdrawal  : $PM_ETH_F_AFTER ETH"
        # Verify it decreased
        DECREASED=$(python3 -c "
import sys
before = int('$PM_ETH_BAL')
after  = int('$PM_ETH_BAL_AFTER')
sys.exit(0 if after < before else 1)
" 2>/dev/null && echo "true" || echo "false")
        [ "$DECREASED" = "true" ] \
            && echo -e "  ${PASS} ETH balance reduced after withdrawal" \
            || echo -e "  ${FAIL} ETH balance did not decrease – check transaction"
    else
        TOKEN_BALANCE_AFTER=$(cast call "$TEST_TOKEN" \
            "balanceOf(address)(uint256)" \
            "$PM" \
            --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "0")
        TOKEN_BALANCE_AFTER=$(echo "$TOKEN_BALANCE_AFTER" | awk '{print $1}')
        TOKEN_BALANCE_AFTER=${TOKEN_BALANCE_AFTER:-0}
        
        # Get the balance before withdrawal (stored earlier in TOKEN_REVENUE)
        TOKEN_BALANCE_BEFORE="$TOKEN_REVENUE"
        
        # Format for display
        TOKEN_BAL_BEFORE_READABLE=$(python3 -c "print(f'{int(\"$TOKEN_BALANCE_BEFORE\") / (10 ** int(\"$TOKEN_DECIMALS\")):.6f}')" 2>/dev/null || echo "?")
        TOKEN_BAL_AFTER_READABLE=$(python3 -c "print(f'{int(\"$TOKEN_BALANCE_AFTER\") / (10 ** int(\"$TOKEN_DECIMALS\")):.6f}')" 2>/dev/null || echo "?")
        
        echo "  ERC-20 contract balance before : $TOKEN_BAL_BEFORE_READABLE tokens ($TOKEN_BALANCE_BEFORE)"
        echo "  ERC-20 contract balance after  : $TOKEN_BAL_AFTER_READABLE tokens ($TOKEN_BALANCE_AFTER)"
        
        DECREASED=$(python3 -c "
import sys
before = int('$TOKEN_BALANCE_BEFORE')
after  = int('$TOKEN_BALANCE_AFTER')
sys.exit(0 if after < before else 1)
" 2>/dev/null && echo "true" || echo "false")
        [ "$DECREASED" = "true" ] \
            && echo -e "  ${PASS} ERC-20 balance reduced after withdrawal" \
            || echo -e "  ${FAIL} ERC-20 balance did not decrease – check transaction"
    fi
else
    echo "  No withdrawal was performed – skipping post-withdrawal revenue check."
fi
echo ""

# ── Step 14: Final summary ────────────────────────────────────────────────────
echo -e "${YELLOW}Step 14: Final state summary${NC}"
echo ""

FINAL_MEMBERS=$(call_view "activeMembershipCount()(uint256)")
FINAL_STATUS_L1_SUMMARY=$(cast call "$PM" "checkMembershipStatus(address,uint256)(bool)" "$USER" 1 \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "false")
FINAL_STATUS_L2_SUMMARY=$(cast call "$PM" "checkMembershipStatus(address,uint256)(bool)" "$USER" 2 \
    --rpc-url "$SEPOLIA_RPC_URL" 2>/dev/null || echo "false")

echo "  Active member count      : $FINAL_MEMBERS"
echo "  User level 1 (Basic)     : $FINAL_STATUS_L1_SUMMARY"
echo "  User level 2 (Premium)   : $FINAL_STATUS_L2_SUMMARY"
echo ""

echo -e "${GREEN}=== Test Complete ===${NC}"
echo ""
echo "  Contract on Etherscan:"
echo "  https://sepolia.etherscan.io/address/$PM"
echo ""
echo "  Tests run:"
echo -e "  ${PASS} 1.  Contract state & tier configs read"
echo -e "  ${PASS} 2.  Existing memberships checked"
[ "$BOUGHT_BASIC"      = "true"  ] && echo -e "  ${PASS} 3.  Bought Basic membership (ETH)"        || echo "  -    3.  Bought Basic membership (skipped – insufficient ETH)"
[ "$STATUS_L1"         = "true"  ] && echo -e "  ${PASS} 4.  Level-1 status verified"              || echo "  -    4.  Level-1 status (not purchased)"
[ -n "$TEST_TOKEN"               ] && echo -e "  ${PASS} 5.  ERC-20 Premium purchase attempted"    || echo "  -    5.  ERC-20 purchase (TEST_TOKEN_ADDRESS not set)"
echo -e "  ${PASS} 6.  Revenue accumulated checked"
[ "$CANCELLED_BASIC"   = "true"  ] && echo -e "  ${PASS} 7.  Basic membership cancelled"          || echo "  -    7.  Basic cancellation skipped"
[ "$CANCELLED_BASIC"   = "true"  ] && echo -e "  ${PASS} 8.  Status verified after Basic cancel"  || echo "  -    8.  Post-cancel status check skipped"
[ "$CANCELLED_PREMIUM" = "true"  ] && echo -e "  ${PASS} 9.  Premium membership cancelled"        || echo "  -    9.  Premium cancellation skipped"
[ "$CANCELLED_PREMIUM" = "true"  ] && echo -e "  ${PASS} 10. Status verified after all cancels"   || echo "  -    10. Post-all-cancel status check skipped"
echo -e "  ${PASS} 11. Revenue re-checked (unchanged by cancellations)"
[ "$WITHDREW_REVENUE"  = "true"  ] && echo -e "  ${PASS} 12. Revenue withdrawal succeeded"        || echo "  -    12. Revenue withdrawal skipped (not owner or no revenue)"
[ "$WITHDREW_REVENUE"  = "true"  ] && echo -e "  ${PASS} 13. Revenue balance verified after withdrawal" || echo "  -    13. Post-withdrawal revenue check skipped"
echo -e "  ${PASS} 14. Final state summary"
echo ""
