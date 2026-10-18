#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] || { echo "Missing .env" >&2; exit 1; }
set -a; source .env; set +a
: "${SEPOLIA_RPC_URL:?SEPOLIA_RPC_URL is required}"
: "${POTENTIAL_RUGPULL_ADDRESS:?Set POTENTIAL_RUGPULL_ADDRESS in .env}"

rpc=(--rpc-url "$SEPOLIA_RPC_URL")
vault="$POTENTIAL_RUGPULL_ADDRESS"
view() { cast call "$vault" "$1" "${@:2}" "${rpc[@]}"; }
chain_id=$(cast chain-id "${rpc[@]}")
[[ "$chain_id" == "11155111" ]] || { echo "Expected Sepolia (11155111), got chain $chain_id" >&2; exit 1; }

owner=$(view 'owner()(address)')
bucket_info=$(view 'bucketInfo()(address)')
cash_ratio=$(view 'cashRatio()(uint256)')
portfolio_value=$(view 'assertedPortfolioValue()(uint256)')
investor_deposits=$(view 'netInvestorDeposits()(uint256)')
withdrawn_value=$(view 'ownerWithdrawnValueUsd8()(uint256)')
floor=$(view 'ownerWithdrawalFloorRequired()(uint256)')
share_price=$(view 'sharePrice()(uint256)')
shares=$(view 'totalSupply()(uint256)')

echo "PotentialRugpull preflight: $vault"
echo "owner=$owner bucketInfo=$bucket_info cashRatio=$cash_ratio assertedPortfolioUsd8=$portfolio_value netInvestorDepositsUsd8=$investor_deposits ownerWithdrawnUsd8=$withdrawn_value withdrawalFloorUsd8=$floor sharePriceUsd8=$share_price totalSupply=$shares"
echo "Read-only smoke completed. No deposit or owner withdrawal is performed by this script."