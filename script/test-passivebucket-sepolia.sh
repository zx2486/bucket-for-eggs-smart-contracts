#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "Missing .env" >&2; exit 1; }
set -a; source .env; set +a
: "${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL is required}"
: "${PASSIVE_BUCKET_PROXY_ADDRESS:?Set PASSIVE_BUCKET_PROXY_ADDRESS in .env}"

rpc=(--rpc-url "$SEPOLIA_RPC_URL")
account=$(cast wallet address --private-key "${PRIVATE_KEY:?Set PRIVATE_KEY in .env}")
if [[ -n "${SMOKE_DEPOSIT_WEI:-}${SMOKE_REBALANCE:-}${SMOKE_REDEEM_BPS:-}" ]]; then
  : "${SMOKE_PRIVATE_KEY:?Set SMOKE_PRIVATE_KEY to a dedicated Sepolia test wallet key for writes}"
  account=$(cast wallet address --private-key "$SMOKE_PRIVATE_KEY")
fi
proxy="$PASSIVE_BUCKET_PROXY_ADDRESS"
view() { cast call "$proxy" "$1" "${@:2}" "${rpc[@]}"; }
uint_value() { awk '{print $1}' <<< "$1"; }
chain_id=$(cast chain-id "${rpc[@]}")
[[ "$chain_id" == "11155111" ]] || { echo "Expected Sepolia (11155111), got chain $chain_id" >&2; exit 1; }

owner=$(view 'owner()(address)')
bucket_info=$(view 'bucketInfo()(address)')
registry=$(view 'REGISTRY()(address)')
paused=$(view 'paused()(bool)')
shares=$(view 'balanceOf(address)(uint256)' "$account")
supply=$(view 'totalSupply()(uint256)')
share_price=$(view 'sharePrice()(uint256)')
total_value=$(view 'calculateTotalValue()(uint256)')
stored=$(view 'getBucketDistributions()((address,uint256)[])')
max_value_loss_bps=$(uint_value "$(view 'maxValueLossBps()(uint256)')")
epoch_value_loss_budget_bps=$(uint_value "$(view 'epochValueLossBudgetBps()(uint256)')")
expected="$(python3 - <<'PY'
import json
c=json.load(open("configs/sepolia.json"))["deployment"]
print(c["bucketInfoAddress"].lower(), c["implementationRegistryAddress"].lower())
PY
)"
read -r expected_bucket_info expected_registry <<< "$expected"

echo "PassiveBucket preflight: $proxy"
echo "owner=$owner account=$account bucketInfo=$bucket_info registry=$registry"
echo "paused=$paused userShares=$shares totalSupply=$supply sharePriceUsd8=$share_price totalValueUsd8=$total_value"
echo "maxValueLossBps=$max_value_loss_bps epochValueLossBudgetBps=$epoch_value_loss_budget_bps"
echo "configuredAllocations=$stored"
bucket_info_lower=$(printf '%s' "$bucket_info" | tr '[:upper:]' '[:lower:]')
registry_lower=$(printf '%s' "$registry" | tr '[:upper:]' '[:lower:]')
[[ "$bucket_info_lower" == "$expected_bucket_info" ]] || { echo "BucketInfo does not match configs/sepolia.json" >&2; exit 1; }
[[ "$registry_lower" == "$expected_registry" ]] || { echo "ImplementationRegistry does not match configs/sepolia.json" >&2; exit 1; }
[[ "$paused" == "false" ]] || { echo "Vault is paused" >&2; exit 1; }
echo "Distribution rebalance entrypoint: rebalanceByDefi() (not sent by default)"
echo "WETH=$(view 'weth()(address)') DEXCount=$(view 'dexCount()(uint8)')"

while read -r token_symbol token_address; do
  valid=$(cast call "$bucket_info" 'isTokenValid(address)(bool)' "$token_address" "${rpc[@]}")
  [[ "$valid" == "true" ]] || { echo "Configured token $token_symbol is not valid in BucketInfo" >&2; exit 1; }
  price_result=$(cast call "$bucket_info" 'tryGetTokenPrice(address)(bool,uint256)' "$token_address" "${rpc[@]}")
  price_available=$(python3 - "$price_result" <<'PY'
import re, sys
match=re.search(r"\b(true|false)\b", sys.argv[1], re.IGNORECASE)
print(match.group(1).lower() if match else "false")
PY
)
  [[ "$price_available" == "true" ]] || {
    echo "Configured token $token_symbol has no usable price (tryGetTokenPrice returned: $price_result)" >&2
    exit 1
  }
done < <(python3 - <<'PY'
import json
c=json.load(open("configs/sepolia.json"))
tokens={item["symbol"]: item["tokenAddress"] for item in c["tokens"]}
for entry in c["deployment"]["passiveBucket"]["distributions"]:
    print(entry["symbol"], tokens[entry["symbol"]])
PY
)

if [[ -z "${SMOKE_DEPOSIT_WEI:-}" && -z "${SMOKE_REBALANCE:-}" && -z "${SMOKE_REDEEM_BPS:-}" ]]; then
  echo "Read-only preflight passed. Set deposit, rebalance, or redeem SMOKE_* variables to opt into transactions."
  exit 0
fi
: "${CONFIRM_SEPOLIA_TEST_TRANSACTIONS:?Set CONFIRM_SEPOLIA_TEST_TRANSACTIONS=YES to allow writes}"
[[ "$CONFIRM_SEPOLIA_TEST_TRANSACTIONS" == "YES" ]] || { echo "Set CONFIRM_SEPOLIA_TEST_TRANSACTIONS=YES to allow writes" >&2; exit 1; }
minted=0
if [[ -n "${SMOKE_DEPOSIT_WEI:-}" ]]; then
  before=$(uint_value "$(view 'balanceOf(address)(uint256)' "$account")")
  cast send "$proxy" 'deposit(address,uint256)' 0x0000000000000000000000000000000000000000 0 --value "$SMOKE_DEPOSIT_WEI" --private-key "$SMOKE_PRIVATE_KEY" "${rpc[@]}"
  after=$(uint_value "$(view 'balanceOf(address)(uint256)' "$account")")
  minted=$(python3 -c 'import sys; print(int(sys.argv[1])-int(sys.argv[2]))' "$after" "$before")
  python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) > 0 else 1)' "$minted" || { echo "Deposit produced no shares" >&2; exit 1; }
  echo "Deposit smoke passed; minted $minted shares."
fi

if [[ -n "${SMOKE_REBALANCE:-}" ]]; then
  caller_shares=$(uint_value "$(view 'balanceOf(address)(uint256)' "$account")")
  python3 -c 'import sys; sys.exit(0 if int(sys.argv[1])>0 else 1)' "$caller_shares" || { echo "Rebalance caller must already hold PassiveBucket shares" >&2; exit 1; }
  cast send "$proxy" 'rebalanceByDefi()' --private-key "$SMOKE_PRIVATE_KEY" "${rpc[@]}"
  echo "rebalanceByDefi smoke transaction submitted."
else
  echo "SMOKE_REBALANCE is not set; skipped rebalanceByDefi()."
fi

redeem_bps="${SMOKE_REDEEM_BPS:-0}"
if (( redeem_bps > 0 )); then
  wallet_shares=$(uint_value "$(view 'balanceOf(address)(uint256)' "$account")")
  share_basis="$wallet_shares"
  if [[ "$minted" != "0" ]]; then share_basis="$minted"; fi
  redeem=$(python3 -c 'import sys; print(int(sys.argv[1])*int(sys.argv[2])//10000)' "$share_basis" "$redeem_bps")
  python3 -c 'import sys; n=int(sys.argv[1]); sys.exit(0 if 0<n<=10000 else 1)' "$redeem_bps" || { echo "SMOKE_REDEEM_BPS must be in 1..10000" >&2; exit 1; }
  python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) > 0 else 1)' "$redeem" || { echo "Redeem amount rounds to zero shares" >&2; exit 1; }
  cast send "$proxy" 'redeem(uint256)' "$redeem" --private-key "$SMOKE_PRIVATE_KEY" "${rpc[@]}"
  echo "Redeemed $redeem shares ($(python3 -c 'import sys; print(f"{int(sys.argv[1])/100:.2f}%")' "$redeem_bps")) of $share_basis shares."
else
  echo "SMOKE_REDEEM_BPS is not set; skipped redeem()."
fi