#!/usr/bin/env bash
#
# Timelock proposal helper. Schedules a governance action, records every parameter
# needed to execute it, and prints the exact command to run once the delay elapses.
#
# The problem this solves: a TimelockController operation's id is a hash of
# (target, value, data, predecessor, salt). Execution must pass the SAME salt and
# predecessor. Lose them and the proposal is unexecutable -- you wait out a fresh
# delay with a salt you did remember. This script never lets that happen: it writes
# a record file at propose time and replays from it at execute time.
#
#   ./script/timelock-propose.sh propose <TIMELOCK> <TARGET> "<SIG>" [ARGS...]
#   ./script/timelock-propose.sh status  <RECORD>
#   ./script/timelock-propose.sh execute <RECORD>
#   ./script/timelock-propose.sh cancel  <RECORD>
#   ./script/timelock-propose.sh list
#
# Env:
#   RPC_URL       required
#   PRIVATE_KEY   required for propose/execute/cancel (omit to print, not send)
#   SALT_LABEL    optional, overrides the generated salt label
#
# Example:
#   RPC_URL=$ROBINHOOD_RPC_URL PRIVATE_KEY=$PK \
#     ./script/timelock-propose.sh propose 0xTimelock 0xVault "setFee(uint256)" 200000000000000000

set -euo pipefail

RECORD_DIR="safe/timelock"
ZERO32="0x0000000000000000000000000000000000000000000000000000000000000000"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found"; }

need cast
need python3

usage() {
    sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'
    exit 64
}

require_rpc() { [ -n "${RPC_URL:-}" ] || die "RPC_URL not set"; }

# Strip cast's "123 [1.2e2]" annotation.
clean() { echo "$1" | awk '{print $1}'; }

# ---------------------------------------------------------------- propose
cmd_propose() {
    [ $# -ge 3 ] || usage
    require_rpc

    local timelock=$1 target=$2 sig=$3
    shift 3

    local calldata
    calldata=$(cast calldata "$sig" "$@")

    local delay
    delay=$(clean "$(cast call "$timelock" "getMinDelay()(uint256)" --rpc-url "$RPC_URL")")

    # Salt: human-readable and unique. Two identical calls with the same salt collide,
    # because a completed operation's id is recorded forever and cannot be rescheduled.
    local label="${SALT_LABEL:-$(echo "$sig" | cut -d'(' -f1)-$(date -u +%Y%m%d-%H%M%S)}"
    local salt
    salt=$(cast format-bytes32-string "$label")

    local id
    id=$(clean "$(cast call "$timelock" \
        "hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)" \
        "$target" 0 "$calldata" "$ZERO32" "$salt" --rpc-url "$RPC_URL")")

    mkdir -p "$RECORD_DIR"
    local record="$RECORD_DIR/${label}.json"
    python3 - "$record" "$timelock" "$target" "$calldata" "$salt" "$id" "$label" "$sig" "$delay" <<'PY'
import json,sys,time
p,tl,tgt,data,salt,oid,label,sig,delay = sys.argv[1:10]
json.dump({
    "label": label, "signature": sig, "timelock": tl, "target": tgt,
    "value": "0", "data": data, "predecessor": "0x" + "00"*32,
    "salt": salt, "operationId": oid, "delay": int(delay),
    "proposedAt": int(time.time()),
}, open(p,"w"), indent=2)
PY

    echo "=============================================================="
    echo " Timelock proposal"
    echo "=============================================================="
    echo " label        : $label"
    echo " call         : $sig"
    echo " target       : $target"
    echo " calldata     : $calldata"
    echo " salt         : $salt"
    echo " predecessor  : $ZERO32"
    echo " operation id : $id"
    echo " delay        : ${delay}s ($((delay / 3600))h)"
    echo " record       : $record"
    echo "=============================================================="

    if [ -z "${PRIVATE_KEY:-}" ]; then
        echo
        echo "PRIVATE_KEY not set. Nothing sent. To schedule, run:"
        echo
        echo "  cast send $timelock \\"
        echo "    \"schedule(address,uint256,bytes,bytes32,bytes32,uint256)\" \\"
        echo "    $target 0 $calldata $ZERO32 $salt $delay \\"
        echo "    --rpc-url \$RPC_URL --private-key \$PK"
        return 0
    fi

    echo
    echo "Scheduling..."
    cast send "$timelock" \
        "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
        "$target" 0 "$calldata" "$ZERO32" "$salt" "$delay" \
        --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
    echo "Scheduled."
    echo
    cmd_status "$record"
}

# ---------------------------------------------------------------- read record
load() {
    local f=$1
    [ -f "$f" ] || die "record not found: $f"
    TL=$(python3 -c "import json;print(json.load(open('$f'))['timelock'])")
    TGT=$(python3 -c "import json;print(json.load(open('$f'))['target'])")
    DATA=$(python3 -c "import json;print(json.load(open('$f'))['data'])")
    SALT=$(python3 -c "import json;print(json.load(open('$f'))['salt'])")
    OID=$(python3 -c "import json;print(json.load(open('$f'))['operationId'])")
    LABEL=$(python3 -c "import json;print(json.load(open('$f'))['label'])")
    SIG=$(python3 -c "import json;print(json.load(open('$f'))['signature'])")
}

# ---------------------------------------------------------------- status
cmd_status() {
    [ $# -eq 1 ] || usage
    require_rpc
    load "$1"

    local ready done_ ts now
    ready=$(cast call "$TL" "isOperationReady(bytes32)(bool)" "$OID" --rpc-url "$RPC_URL")
    done_=$(cast call "$TL" "isOperationDone(bytes32)(bool)" "$OID" --rpc-url "$RPC_URL")
    ts=$(clean "$(cast call "$TL" "getTimestamp(bytes32)(uint256)" "$OID" --rpc-url "$RPC_URL")")
    now=$(clean "$(cast block latest -f timestamp --rpc-url "$RPC_URL")")

    echo "--------------------------------------------------------------"
    echo " $LABEL"
    echo "   call         : $SIG"
    echo "   operation id : $OID"

    if [ "$ts" = "0" ]; then
        echo "   state        : NOT SCHEDULED (or cancelled)"
    elif [ "$done_" = "true" ]; then
        echo "   state        : DONE"
    elif [ "$ready" = "true" ]; then
        echo "   state        : READY — execute now"
    else
        echo "   state        : PENDING — $((ts - now))s remaining ($(( (ts - now) / 3600 ))h)"
        echo "   ready at     : $ts (now $now)"
    fi
    echo "--------------------------------------------------------------"

    if [ "$ready" = "true" ] && [ "$done_" = "false" ]; then
        echo
        echo "Execute with:"
        echo "  ./script/timelock-propose.sh execute $1"
    fi
}

# ---------------------------------------------------------------- execute
cmd_execute() {
    [ $# -eq 1 ] || usage
    require_rpc
    load "$1"

    local ready
    ready=$(cast call "$TL" "isOperationReady(bytes32)(bool)" "$OID" --rpc-url "$RPC_URL")
    [ "$ready" = "true" ] || { cmd_status "$1"; die "operation is not ready"; }

    if [ -z "${PRIVATE_KEY:-}" ]; then
        echo "PRIVATE_KEY not set. To execute, run:"
        echo
        echo "  cast send $TL \\"
        echo "    \"execute(address,uint256,bytes,bytes32,bytes32)\" \\"
        echo "    $TGT 0 $DATA $ZERO32 $SALT \\"
        echo "    --rpc-url \$RPC_URL --private-key \$PK"
        return 0
    fi

    echo "Executing $LABEL ..."
    cast send "$TL" "execute(address,uint256,bytes,bytes32,bytes32)" \
        "$TGT" 0 "$DATA" "$ZERO32" "$SALT" \
        --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
    echo "Executed."
    cmd_status "$1"
}

# ---------------------------------------------------------------- cancel
cmd_cancel() {
    [ $# -eq 1 ] || usage
    require_rpc
    load "$1"

    if [ -z "${PRIVATE_KEY:-}" ]; then
        echo "PRIVATE_KEY not set. To cancel, run:"
        echo "  cast send $TL \"cancel(bytes32)\" $OID --rpc-url \$RPC_URL --private-key \$PK"
        return 0
    fi

    cast send "$TL" "cancel(bytes32)" "$OID" \
        --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" >/dev/null
    echo "Cancelled $LABEL"
}

# ---------------------------------------------------------------- list
cmd_list() {
    [ -d "$RECORD_DIR" ] || { echo "no proposals in $RECORD_DIR"; return 0; }
    local found=0
    for f in "$RECORD_DIR"/*.json; do
        [ -e "$f" ] || continue
        found=1
        if [ -n "${RPC_URL:-}" ]; then cmd_status "$f"; else
            echo "  $f"
        fi
    done
    [ "$found" = "1" ] || echo "no proposals in $RECORD_DIR"
}

# ---------------------------------------------------------------- dispatch
[ $# -ge 1 ] || usage
sub=$1; shift
case "$sub" in
    propose) cmd_propose "$@" ;;
    status)  cmd_status  "$@" ;;
    execute) cmd_execute "$@" ;;
    cancel)  cmd_cancel  "$@" ;;
    list)    cmd_list    "$@" ;;
    *)       usage ;;
esac
