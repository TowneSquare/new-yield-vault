#!/usr/bin/env bash
#
# Preflight checks for a REBALANCER_ROLE P&L report.
#
#   ./script/rebalancer-preflight.sh <YIELD_PROXY> <VAULT_PROXY> <RPC_URL>
#
# Reads live state and prints the next valid nonce, whether the rate limit has
# elapsed, and the computed ceilings for `amount` and `feeAmount`.
#
# Reads only. Sends nothing. See gitbook/operations/reporting-pnl.md.

set -euo pipefail

if [ $# -ne 3 ]; then
    echo "usage: $0 <YIELD_PROXY> <VAULT_PROXY> <RPC_URL>" >&2
    exit 64
fi

YIELD=$1
VAULT=$2
RPC=$3

command -v cast >/dev/null 2>&1 || { echo "error: cast not found (install Foundry)" >&2; exit 69; }

call() { cast call "$1" "$2" --rpc-url "$RPC"; }

EPOCH=$(call "$YIELD" "epoch()(uint256)")
LAST=$(call "$YIELD" "lastDistributionTime()(uint256)")
INTERVAL=$(call "$YIELD" "minDistributionInterval()(uint256)")
MAX_YIELD_BPS=$(call "$YIELD" "maxYieldPercentage()(uint256)")
MAX_FEE_BPS=$(call "$YIELD" "maxFeePercentage()(uint256)")
DEBT=$(call "$YIELD" "treasuryDebt()(uint256)")

TOTAL_ASSETS=$(call "$VAULT" "totalAssets()(uint256)")
UNVESTED=$(call "$VAULT" "getUnvestedAmount()(uint256)")
REQUESTED=$(call "$VAULT" "totalRequestedAmount()(uint256)")
ASSET=$(call "$VAULT" "asset()(address)")

ASSET_DECIMALS=$(cast call "$ASSET" "decimals()(uint8)" --rpc-url "$RPC")
ASSET_SYMBOL=$(cast call "$ASSET" "symbol()(string)" --rpc-url "$RPC" | tr -d '"')
VAULT_BALANCE=$(cast call "$ASSET" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$RPC")

NOW=$(cast block latest -f timestamp --rpc-url "$RPC")

# `cast call` may return "123 [1.23e2]" — keep the leading integer only.
strip() { echo "$1" | awk '{print $1}'; }
EPOCH=$(strip "$EPOCH");                 LAST=$(strip "$LAST")
INTERVAL=$(strip "$INTERVAL");           MAX_YIELD_BPS=$(strip "$MAX_YIELD_BPS")
MAX_FEE_BPS=$(strip "$MAX_FEE_BPS");     DEBT=$(strip "$DEBT")
TOTAL_ASSETS=$(strip "$TOTAL_ASSETS");   UNVESTED=$(strip "$UNVESTED")
REQUESTED=$(strip "$REQUESTED");         VAULT_BALANCE=$(strip "$VAULT_BALANCE")
ASSET_DECIMALS=$(strip "$ASSET_DECIMALS")

READY_AT=$((LAST + INTERVAL))
MAX_AMOUNT=$((TOTAL_ASSETS * MAX_YIELD_BPS / 10000))

# Render a raw integer in the asset's own decimals.
fmt() { python3 -c "print(f'{int($1) / 10**int($ASSET_DECIMALS):,.6f}')"; }

echo "=============================================================="
echo " Rebalancer preflight"
echo "=============================================================="
echo " asset              : $ASSET_SYMBOL ($ASSET_DECIMALS decimals)"
echo " totalAssets        : $TOTAL_ASSETS  ($(fmt "$TOTAL_ASSETS") $ASSET_SYMBOL)"
echo " unvested profit    : $UNVESTED  ($(fmt "$UNVESTED") $ASSET_SYMBOL)"
echo
echo " current epoch      : $EPOCH"
echo " NEXT NONCE         : $((EPOCH + 1))"
echo
echo " last report        : $LAST"
echo " interval           : $INTERVAL s"
echo " ready at           : $READY_AT   (now $NOW)"
if [ "$NOW" -ge "$READY_AT" ]; then
    echo " STATUS             : READY"
else
    echo " STATUS             : TOO EARLY — $((READY_AT - NOW))s remaining"
fi
echo
echo " maxYieldPercentage : $MAX_YIELD_BPS bps"
echo " MAX amount         : $MAX_AMOUNT  ($(fmt "$MAX_AMOUNT") $ASSET_SYMBOL)"
echo " maxFeePercentage   : $MAX_FEE_BPS bps"
echo " MAX feeAmount      : amount * $MAX_FEE_BPS / 10000"
echo
echo " treasuryDebt       : $DEBT"
[ "$DEBT" != "0" ] && echo "                      (fees route to depositors until cleared)"
echo
echo " pending redemptions: $REQUESTED  ($(fmt "$REQUESTED") $ASSET_SYMBOL)"
echo " vault balance      : $VAULT_BALANCE  ($(fmt "$VAULT_BALANCE") $ASSET_SYMBOL)"
if [ "$VAULT_BALANCE" -lt "$REQUESTED" ]; then
    echo " FUNDING            : SHORTFALL — matured redemptions are NOT all payable."
    echo "                      Needs Manager.transferToVault (OPERATOR_ROLE)."
else
    echo " FUNDING            : ok"
fi
echo "=============================================================="
echo
echo "REMINDERS"
echo "  * feeAmount is ADDITIVE, not deducted from amount."
echo "    5 $ASSET_SYMBOL realised at a 20% fee -> amount=4e$ASSET_DECIMALS, feeAmount=1e$ASSET_DECIMALS"
echo "  * Both values are in $ASSET_DECIMALS decimals, not 18."
echo "  * The amount cap is evaluated against LIVE totalAssets at execution."
echo "  * Simulate first:"
echo "      cast call $YIELD \"distributeYield(uint256,uint256,uint256,bool)\" \\"
echo "        <amount> <feeAmount> $((EPOCH + 1)) <isProfit> --from <rebalancer> --rpc-url <rpc>"
echo "  * There is no reversal path. A bad report unwinds only over later epochs."
