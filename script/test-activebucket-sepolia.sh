#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "Missing .env" >&2; exit 1; }
set -a; source .env; set +a
: "${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL is required}"
: "${ACTIVE_BUCKET_PROXY_ADDRESS:?Set ACTIVE_BUCKET_PROXY_ADDRESS in .env}"

rpc=(--rpc-url "$SEPOLIA_RPC_URL")
account=$(cast wallet address --private-key "${PRIVATE_KEY:?Set PRIVATE_KEY in .env}")
if [[ -n "${SMOKE_DEPOSIT_WEI:-}${SMOKE_REDEEM_SHARES:-}${SMOKE_REDEEM_FOR_STABLE_BPS:-}" ]]; then
  : "${SMOKE_PRIVATE_KEY:?Set SMOKE_PRIVATE_KEY to a dedicated Sepolia test wallet key for writes}"
  account=$(cast wallet address --private-key "$SMOKE_PRIVATE_KEY")
fi
proxy="$ACTIVE_BUCKET_PROXY_ADDRESS"
view() { cast call "$proxy" "$1" "${@:2}" "${rpc[@]}"; }
chain_id=$(cast chain-id "${rpc[@]}")
[[ "$chain_id" == "11155111" ]] || { echo "Expected Sepolia (11155111), got chain $chain_id" >&2; exit 1; }

owner=$(view 'owner()(address)')
bucket_info=$(view 'bucketInfo()(address)')
registry=$(view 'REGISTRY()(address)')
paused=$(view 'paused()(bool)')
swap_paused=$(view 'swapPaused()(bool)')
shares=$(view 'balanceOf(address)(uint256)' "$account")
supply=$(view 'totalSupply()(uint256)')
share_price=$(view 'sharePrice()(uint256)')
total_value=$(view 'calculateTotalValue()(uint256)')
fee=$(view 'performanceFeeBps()(uint256)')
expected_fee=$(python3 -c 'import json; print(json.load(open("configs/sepolia.json"))["deployment"]["activeBucket"]["performanceFeeBps"])')

echo "ActiveBucket preflight: $proxy"
echo "owner=$owner account=$account bucketInfo=$bucket_info registry=$registry"
echo "paused=$paused swapPaused=$swap_paused userShares=$shares totalSupply=$supply sharePriceUsd8=$share_price totalValueUsd8=$total_value performanceFeeBps=$fee"
expected_bucket_info=$(python3 -c 'import json; print(json.load(open("configs/sepolia.json"))["deployment"]["bucketInfoAddress"].lower())')
[[ "${bucket_info,,}" == "$expected_bucket_info" ]] || { echo "BucketInfo does not match configs/sepolia.json" >&2; exit 1; }
[[ "$paused" == "false" ]] || { echo "Vault is paused" >&2; exit 1; }
[[ "$swap_paused" == "false" || -z "${SMOKE_REDEEM_FOR_STABLE_BPS:-}" ]] || { echo "Swaps are paused; redeemForStable cannot execute" >&2; exit 1; }
[[ "$fee" == "$expected_fee" ]] || { echo "Performance fee differs from configs/sepolia.json" >&2; exit 1; }

if [[ -z "${SMOKE_DEPOSIT_WEI:-}" && -z "${SMOKE_REDEEM_SHARES:-}" && -z "${SMOKE_REDEEM_FOR_STABLE_BPS:-}" ]]; then
  echo "Read-only preflight passed. Set SMOKE_DEPOSIT_WEI or a redeem variable to opt into test transactions."
  exit 0
fi
: "${CONFIRM_SEPOLIA_TEST_TRANSACTIONS:?Set CONFIRM_SEPOLIA_TEST_TRANSACTIONS=YES to allow writes}"
[[ "$CONFIRM_SEPOLIA_TEST_TRANSACTIONS" == "YES" ]] || { echo "Set CONFIRM_SEPOLIA_TEST_TRANSACTIONS=YES to allow writes" >&2; exit 1; }

minted=0
if [[ -n "${SMOKE_DEPOSIT_WEI:-}" ]]; then
before=$(view 'balanceOf(address)(uint256)' "$account")
  cast send "$proxy" 'deposit(address,uint256)' 0x0000000000000000000000000000000000000000 0 --value "$SMOKE_DEPOSIT_WEI" --private-key "$SMOKE_PRIVATE_KEY" "${rpc[@]}"
after=$(view 'balanceOf(address)(uint256)' "$account")
minted=$(python3 -c 'import sys; print(int(sys.argv[1])-int(sys.argv[2]))' "$after" "$before")
python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) > 0 else 1)' "$minted" || { echo "Deposit produced no shares" >&2; exit 1; }
echo "Deposit smoke passed; minted $minted shares."
fi

if [[ -n "${SMOKE_REDEEM_FOR_STABLE_BPS:-}" ]]; then
  [[ -z "${SMOKE_REDEEM_SHARES:-}" ]] || { echo "Choose only one of SMOKE_REDEEM_SHARES and SMOKE_REDEEM_FOR_STABLE_BPS" >&2; exit 1; }
  bps="$SMOKE_REDEEM_FOR_STABLE_BPS"
  python3 -c 'import sys; n=int(sys.argv[1]); sys.exit(0 if 0<n<=10000 else 1)' "$bps" || { echo "SMOKE_REDEEM_FOR_STABLE_BPS must be 1..10000" >&2; exit 1; }
  stable_symbol="${SMOKE_STABLE_TOKEN_SYMBOL:-USDC}"
  dst_token=$(python3 - "$stable_symbol" <<'PY'
import json, sys
symbol=sys.argv[1]
for token in json.load(open("configs/sepolia.json"))["tokens"]:
    if token["symbol"].lower() == symbol.lower():
        print(token["tokenAddress"])
        raise SystemExit(0)
raise SystemExit(f"Token {symbol} is not in configs/sepolia.json")
PY
)
  slippage="${SMOKE_MAX_SLIPPAGE_BPS:-50}"
  python3 -c 'import sys; n=int(sys.argv[1]); sys.exit(0 if 0<=n<=100 else 1)' "$slippage" || { echo "SMOKE_MAX_SLIPPAGE_BPS must be 0..100" >&2; exit 1; }
  share_basis=$(view 'balanceOf(address)(uint256)' "$account")
  if [[ -n "${SMOKE_DEPOSIT_WEI:-}" ]]; then share_basis="$minted"; fi
  redeem=$(python3 -c 'import sys; print(int(sys.argv[1])*int(sys.argv[2])//10000)' "$share_basis" "$bps")
  python3 -c 'import sys; sys.exit(0 if int(sys.argv[1]) > 0 else 1)' "$redeem" || { echo "Stable redemption rounds to zero shares" >&2; exit 1; }
  dst_valid=$(cast call "$bucket_info" 'isTokenValid(address)(bool)' "$dst_token" "${rpc[@]}")
  [[ "$dst_valid" == "true" ]] || { echo "Destination token $stable_symbol is not valid in BucketInfo" >&2; exit 1; }
  echo "Redeem request: $redeem shares ($(python3 -c 'import sys; print(f"{int(sys.argv[1])/100:.2f}%")' "$bps")) of $share_basis shares to $stable_symbol ($dst_token), slippage cap ${slippage} bps"
  if ! simulation=$(cast call "$proxy" 'redeemForStable(uint256,address,uint256)' "$redeem" "$dst_token" "$slippage" --from "$(cast wallet address --private-key "$SMOKE_PRIVATE_KEY")" "${rpc[@]}" 2>&1); then
    echo "redeemForStable simulation reverted; no transaction was sent:" >&2
    echo "$simulation" >&2
    exit 1
  fi
  echo "Simulation succeeded: $simulation"
  cast send "$proxy" 'redeemForStable(uint256,address,uint256)' "$redeem" "$dst_token" "$slippage" --private-key "$SMOKE_PRIVATE_KEY" "${rpc[@]}"
  echo "redeemForStable transaction submitted."
fi

if [[ -n "${SMOKE_REDEEM_SHARES:-}" ]]; then
  wallet_shares=$(view 'balanceOf(address)(uint256)' "$account")
  python3 -c 'import sys; n,bal=map(int,sys.argv[1:]); sys.exit(0 if 0<n<=bal else 1)' "$SMOKE_REDEEM_SHARES" "$wallet_shares" || { echo "SMOKE_REDEEM_SHARES exceeds wallet balance" >&2; exit 1; }
  cast send "$proxy" 'redeem(uint256)' "$SMOKE_REDEEM_SHARES" --private-key "$SMOKE_PRIVATE_KEY" "${rpc[@]}"
  echo "Redeemed $SMOKE_REDEEM_SHARES shares."
fi
