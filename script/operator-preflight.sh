#!/usr/bin/env bash
#
# Preflight checks for an OPERATOR_ROLE capital deployment via Manager.execute.
#
#   ./script/operator-preflight.sh <MANAGER> <VAULT> <RPC_URL> <target> [<target> ...]
#
# Verifies each target is whitelisted, prints Manager/vault balances, and reports
# whether pending redemptions are currently funded.
#
# Reads only. Sends nothing. See gitbook/operations/deploying-capital.md.

set -euo pipefail

if [ $# -lt 4 ]; then
    echo "usage: $0 <MANAGER> <VAULT> <RPC_URL> <target> [<target> ...]" >&2
    exit 64
fi

MANAGER=$1; VAULT=$2; RPC=$3
shift 3
TARGETS=("$@")

command -v cast >/dev/null 2>&1 || { echo "error: cast not found (install Foundry)" >&2; exit 69; }

# `cast call` may return "123 [1.23e2]" — keep the leading token only.
strip() { echo "$1" | awk '{print $1}'; }
call()  { strip "$(cast call "$1" "$2" --rpc-url "$RPC")"; }

ASSET=$(call "$VAULT" "asset()(address)")
DECIMALS=$(call "$ASSET" "decimals()(uint8)")
SYMBOL=$(cast call "$ASSET" "symbol()(string)" --rpc-url "$RPC" | tr -d '"')

MANAGER_BAL=$(strip "$(cast call "$ASSET" "balanceOf(address)(uint256)" "$MANAGER" --rpc-url "$RPC")")
VAULT_BAL=$(strip "$(cast call "$ASSET" "balanceOf(address)(uint256)" "$VAULT" --rpc-url "$RPC")")
REQUESTED=$(call "$VAULT" "totalRequestedAmount()(uint256)")

fmt() { python3 -c "print(f'{int($1) / 10**int($DECIMALS):,.6f}')"; }

echo "=============================================================="
echo " Operator preflight"
echo "=============================================================="
echo " asset            : $SYMBOL ($DECIMALS decimals)"
echo " manager balance  : $MANAGER_BAL  ($(fmt "$MANAGER_BAL") $SYMBOL)"
echo " vault balance    : $VAULT_BAL  ($(fmt "$VAULT_BAL") $SYMBOL)"
echo " pending redeems  : $REQUESTED  ($(fmt "$REQUESTED") $SYMBOL)"

if [ "$VAULT_BAL" -lt "$REQUESTED" ]; then
    SHORT=$((REQUESTED - VAULT_BAL))
    echo " FUNDING          : SHORTFALL of $SHORT  ($(fmt "$SHORT") $SYMBOL)"
    echo
    echo " Matured redemptions are NOT all payable. Consider funding the vault"
    echo " BEFORE deploying more capital:"
    echo "   cast send $MANAGER \"transferToVault(address,uint256)\" $ASSET $SHORT \\"
    echo "     --rpc-url <rpc> --private-key \$PK"
else
    echo " FUNDING          : ok — pending redemptions are covered"
fi

echo
echo "--------------------------------------------------------------"
echo " Whitelist status"
echo "--------------------------------------------------------------"

BLOCKED=0
for t in "${TARGETS[@]}"; do
    ok=$(cast call "$MANAGER" "whitelistedAddresses(address)(bool)" "$t" --rpc-url "$RPC")
    if [ "$ok" = "true" ]; then
        printf " OK       %s\n" "$t"
    else
        printf " BLOCKED  %s\n" "$t"
        BLOCKED=$((BLOCKED + 1))
    fi
done

echo "--------------------------------------------------------------"
if [ "$BLOCKED" -gt 0 ]; then
    echo " $BLOCKED target(s) NOT whitelisted — execute would revert with NotWhitelisted."
    echo " Whitelisting is ADMIN_ROLE, not OPERATOR_ROLE."
else
    echo " All targets whitelisted."
fi
echo "=============================================================="
echo
echo "REMINDERS"
echo "  * Amounts are in $DECIMALS decimals, not 18."
echo "  * execute has NO amount cap, NO rate limit, and NO reentrancy guard."
echo "  * The batch is atomic: one failing call reverts everything."
echo "  * Prefer exact approvals over infinite ones."
echo "  * Simulate before sending:"
echo "      cast call $MANAGER \"execute(address[],bytes[])(bytes[])\" \\"
echo "        \"[<targets>]\" \"[<calldata>]\" --from <operator> --rpc-url <rpc>"

exit $(( BLOCKED > 0 ? 1 : 0 ))
