#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "Missing .env" >&2; exit 1; }
set -a; source .env; set +a
: "${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL is required}"
: "${PURE_MEMBERSHIP_PROXY_ADDRESS:?Set PURE_MEMBERSHIP_PROXY_ADDRESS in .env}"

rpc=(--rpc-url "$SEPOLIA_RPC_URL")
account=$(cast wallet address --private-key "${PRIVATE_KEY:?Set PRIVATE_KEY in .env}")
if [[ -n "${SMOKE_MEMBERSHIP_TOKEN_ID:-}" ]]; then
  : "${SMOKE_PRIVATE_KEY:?Set SMOKE_PRIVATE_KEY to a dedicated Sepolia test wallet key for writes}"
  account=$(cast wallet address --private-key "$SMOKE_PRIVATE_KEY")
fi
proxy="$PURE_MEMBERSHIP_PROXY_ADDRESS"
view() { cast call "$proxy" "$1" "${@:2}" "${rpc[@]}"; }
chain_id=$(cast chain-id "${rpc[@]}")
[[ "$chain_id" == "11155111" ]] || { echo "Expected Sepolia (11155111), got chain $chain_id" >&2; exit 1; }

owner=$(view 'owner()(address)')
bucket_info=$(view 'bucketInfo()(address)')
paused=$(view 'paused()(bool)')
tier_count=$(view 'getConfiguredTokenIdCount()(uint256)')
echo "PureMembership preflight: $proxy"
echo "owner=$owner account=$account bucketInfo=$bucket_info paused=$paused configuredTiers=$tier_count"
[[ "$paused" == "false" ]] || { echo "Membership contract is paused" >&2; exit 1; }
(( tier_count > 0 )) || { echo "No membership tiers are configured" >&2; exit 1; }

for ((i=0; i<tier_count; i++)); do
  token_id=$(view 'configuredTokenIds(uint256)(uint256)' "$i")
  config=$(view 'getMembershipInfo(uint256)((uint256,uint256,string,uint256,uint256))' "$token_id")
  echo "tier[$i] tokenId=$token_id config=$config"
done

if [[ -z "${SMOKE_MEMBERSHIP_TOKEN_ID:-}" ]]; then
  echo "Read-only preflight passed. Set SMOKE_MEMBERSHIP_TOKEN_ID and SMOKE_MEMBERSHIP_PAY_SECTION to opt into a purchase."
  exit 0
fi
: "${CONFIRM_SEPOLIA_TEST_TRANSACTIONS:?Set CONFIRM_SEPOLIA_TEST_TRANSACTIONS=YES to allow writes}"
[[ "$CONFIRM_SEPOLIA_TEST_TRANSACTIONS" == "YES" ]] || { echo "Set CONFIRM_SEPOLIA_TEST_TRANSACTIONS=YES to allow writes" >&2; exit 1; }
: "${SMOKE_MEMBERSHIP_PAY_SECTION:=1}"
[[ "$SMOKE_MEMBERSHIP_PAY_SECTION" =~ ^[0-9]+$ ]] || { echo "SMOKE_MEMBERSHIP_PAY_SECTION must be an integer" >&2; exit 1; }
(( SMOKE_MEMBERSHIP_PAY_SECTION > 0 )) || { echo "Pay section count must be positive for this smoke test" >&2; exit 1; }
(( SMOKE_MEMBERSHIP_PAY_SECTION <= 12 )) || { echo "Pay section count is capped at 12 for smoke testing" >&2; exit 1; }
found_tier=false
for ((i=0; i<tier_count; i++)); do
  configured_id=$(view 'configuredTokenIds(uint256)(uint256)' "$i")
  if [[ "$configured_id" == "$SMOKE_MEMBERSHIP_TOKEN_ID" ]]; then found_tier=true; fi
done
[[ "$found_tier" == "true" ]] || { echo "SMOKE_MEMBERSHIP_TOKEN_ID is not configured" >&2; exit 1; }
payment_token="${SMOKE_MEMBERSHIP_PAYMENT_TOKEN:-0x0000000000000000000000000000000000000000}"
payment_limit="${SMOKE_MEMBERSHIP_MAX_PAYMENT:-}"
payment_valid=$(cast call "$bucket_info" 'isTokenValid(address)(bool)' "$payment_token" "${rpc[@]}")
[[ "$payment_valid" == "true" ]] || { echo "Membership payment token is not valid in BucketInfo" >&2; exit 1; }
if [[ "$payment_token" == "0x0000000000000000000000000000000000000000" ]]; then
  if [[ -z "$payment_limit" ]]; then
    tier_config=$(view 'getMembershipInfo(uint256)((uint256,uint256,string,uint256,uint256))' "$SMOKE_MEMBERSHIP_TOKEN_ID")
    price_usd8=$(python3 - "$tier_config" <<'PY'
import re, sys
matches=re.findall(r"\d+", sys.argv[1])
    if len(matches) < 4:
    raise SystemExit("Unable to decode tier price from getMembershipInfo result")
    print(matches[2])
PY
)
    eth_price_result=$(cast call "$bucket_info" 'getTokenPrice(address)(uint256)' "$payment_token" "${rpc[@]}")
    eth_price_usd8=$(awk '{print $1}' <<< "$eth_price_result")
    buffer_bps="${SMOKE_MEMBERSHIP_BUFFER_BPS:-2000}"
    python3 -c 'import sys; b=int(sys.argv[1]); sys.exit(0 if 0<=b<=10000 else 1)' "$buffer_bps" || { echo "SMOKE_MEMBERSHIP_BUFFER_BPS must be 0..10000" >&2; exit 1; }
    payment_limit=$(python3 - "$price_usd8" "$eth_price_usd8" "$SMOKE_MEMBERSHIP_PAY_SECTION" "$buffer_bps" <<'PY'
import sys
price, eth_price, sections, buffer = map(int, sys.argv[1:])
if price <= 0 or eth_price <= 0:
    raise SystemExit("Tier price and ETH oracle price must be nonzero")
# buyMembership computes floor(priceUsd8 * sections * 1e18 / ethPriceUsd8).
base = price * sections * 10**18 // eth_price
cap = (base * (10_000 + buffer) + 9_999) // 10_000
print(cap)
PY
)
    echo "Calculated maxPay cap: $payment_limit wei ($buffer_bps bps buffer)."
  fi
  python3 -c 'import sys; v=int(sys.argv[1]); sys.exit(0 if 0 < v <= 10**18 else 1)' "$payment_limit" || { echo "ETH spend cap must be positive and <= 1 ETH" >&2; exit 1; }
  cast send "$proxy" 'buyMembership(uint256,address,uint256)' "$SMOKE_MEMBERSHIP_TOKEN_ID" "$payment_token" "$SMOKE_MEMBERSHIP_PAY_SECTION" --value "$payment_limit" --private-key "$SMOKE_PRIVATE_KEY" "${rpc[@]}"
else
  echo "ERC-20 payment smoke requires token approval and a raw-unit SMOKE_MEMBERSHIP_MAX_PAYMENT cap. This script does not create token approvals." >&2
  exit 1
fi

expiry=$(view 'membershipExpiry(address,uint256)(uint256)' "$account" "$SMOKE_MEMBERSHIP_TOKEN_ID")
echo "Purchase transaction confirmed; expiry=$expiry"