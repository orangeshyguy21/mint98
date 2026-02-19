#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Cashu Mint Activity Simulator
# Continuously simulates mint, melt, and swap operations using cdk-cli
# and Polar LND nodes to generate realistic mint traffic.
# =============================================================================

# ---- Configuration ----------------------------------------------------------

MINT_URL="${MINT_URL:-http://localhost:5551}"
CDK_CLI="${CDK_CLI:-$HOME/Sites/cdk/target/release/cdk-cli}"
UNIT="${UNIT:-sat}"

# Polar LND node containers (docker exec targets)
FUNDING_NODE="${FUNDING_NODE:-polar-n4-bob}"     # Pays invoices TO the mint (funding)
INVOICE_NODE="${INVOICE_NODE:-polar-n4-frank}"    # Receives payments FROM the mint (melting)
BACKUP_NODE="${BACKUP_NODE:-polar-n4-dave}"       # Alternate node for variety

ALL_NODES=("$FUNDING_NODE" "$INVOICE_NODE" "$BACKUP_NODE")

# Per-node lncli flags (litd vs plain lnd have different paths)
LITD_ARGS="--tlscertpath /home/litd/.lnd/tls.cert --macaroonpath /home/litd/.lnd/data/chain/bitcoin/regtest/admin.macaroon --network regtest"
LND_ARGS="--tlscertpath /home/lnd/.lnd/tls.cert --macaroonpath /home/lnd/.lnd/data/chain/bitcoin/regtest/admin.macaroon --network regtest"

# Returns the correct lncli args for a given node
lncli_args_for() {
    case "$1" in
        polar-n4-frank) echo "$LND_ARGS" ;;
        *)              echo "$LITD_ARGS" ;;
    esac
}

# Timing (seconds)
MIN_DELAY="${MIN_DELAY:-5}"
MAX_DELAY="${MAX_DELAY:-30}"

# Amounts (sats)
MIN_AMOUNT="${MIN_AMOUNT:-10}"
MAX_AMOUNT="${MAX_AMOUNT:-500}"

# Minimum balance required before attempting melt/swap
MIN_BALANCE_FOR_SPEND=20

# Logging
LOG_FILE="${LOG_FILE:-./mint-sim.log}"

# ---- Counters ---------------------------------------------------------------

MINT_COUNT=0
MELT_COUNT=0
SWAP_COUNT=0
FAIL_COUNT=0
START_TIME=$(date +%s)

# ---- Helpers ----------------------------------------------------------------

log() {
    local level="$1"
    shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

random_in_range() {
    local min=$1 max=$2
    echo $(( RANDOM % (max - min + 1) + min ))
}

random_amount() {
    random_in_range "$MIN_AMOUNT" "$MAX_AMOUNT"
}

random_delay() {
    local delay
    delay=$(random_in_range "$MIN_DELAY" "$MAX_DELAY")
    log "INFO" "Sleeping ${delay}s before next operation..."
    sleep "$delay"
}

random_funding_node() {
    # Pick from funding or backup node for variety
    local nodes=("$FUNDING_NODE" "$BACKUP_NODE")
    echo "${nodes[$((RANDOM % ${#nodes[@]}))]}"
}

random_invoice_node() {
    # Pick from invoice or backup node for variety
    local nodes=("$INVOICE_NODE" "$BACKUP_NODE")
    echo "${nodes[$((RANDOM % ${#nodes[@]}))]}"
}

check_balance() {
    local output
    output=$($CDK_CLI balance 2>&1) || true
    # Try to extract a numeric balance from the output
    # cdk-cli balance typically shows something like: "Mint: <url> Balance: <amount> <unit>"
    local balance
    balance=$(echo "$output" | grep -oE '[0-9]+' | tail -1 || echo "0")
    echo "${balance:-0}"
}

print_summary() {
    local elapsed=$(( $(date +%s) - START_TIME ))
    local hours=$(( elapsed / 3600 ))
    local mins=$(( (elapsed % 3600) / 60 ))
    local secs=$(( elapsed % 60 ))
    log "INFO" "========== SESSION SUMMARY =========="
    log "INFO" "Runtime: ${hours}h ${mins}m ${secs}s"
    log "INFO" "Mints:  $MINT_COUNT"
    log "INFO" "Melts:  $MELT_COUNT"
    log "INFO" "Swaps:  $SWAP_COUNT"
    log "INFO" "Fails:  $FAIL_COUNT"
    log "INFO" "Total:  $(( MINT_COUNT + MELT_COUNT + SWAP_COUNT ))"
    log "INFO" "Final balance: $(check_balance) sats"
    log "INFO" "===================================="
}

# ---- Graceful Shutdown ------------------------------------------------------

cleanup() {
    log "INFO" "Caught shutdown signal, stopping..."
    print_summary
    exit 0
}

trap cleanup SIGINT SIGTERM

# ---- Core Operations --------------------------------------------------------

do_mint_cycle() {
    local amount node invoice
    amount=$(random_amount)
    node=$(random_funding_node)

    log "MINT" "Starting mint cycle: ${amount} sats via $node"

    # cdk-cli mint is blocking — it prints the invoice then waits for payment.
    # We must run it in the background, grab the invoice from its output, pay it,
    # then wait for cdk-cli to finish receiving the proofs.

    local tmpfile
    tmpfile=$(mktemp /tmp/mint-sim-XXXXXX)

    # Step 1: Run cdk-cli mint in background, streaming output to tmpfile
    $CDK_CLI mint "$MINT_URL" "$amount" > "$tmpfile" 2>&1 &
    local mint_pid=$!

    # Step 2: Wait for the invoice to appear in the output (poll tmpfile)
    local waited=0
    invoice=""
    while [ $waited -lt 30 ]; do
        invoice=$(grep -oE 'lnbc[a-zA-Z0-9]+' "$tmpfile" 2>/dev/null | head -1 || true)
        if [ -n "$invoice" ]; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if [ -z "$invoice" ]; then
        log "ERROR" "Timed out waiting for invoice from cdk-cli mint. Output: $(cat "$tmpfile")"
        kill "$mint_pid" 2>/dev/null || true
        rm -f "$tmpfile"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    log "MINT" "Got invoice: ${invoice:0:40}..."

    # Step 3: Pay the invoice from the LND node
    local pay_output
    pay_output=$(docker exec "$node" lncli $(lncli_args_for "$node") payinvoice --force "$invoice" 2>&1) || {
        log "ERROR" "Failed to pay invoice from $node: $pay_output"
        kill "$mint_pid" 2>/dev/null || true
        rm -f "$tmpfile"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    }

    log "MINT" "Invoice paid by $node"

    # Step 4: Wait for cdk-cli mint to finish (it should complete now that invoice is paid)
    wait "$mint_pid" 2>/dev/null || true
    log "MINT" "cdk-cli mint output: $(cat "$tmpfile")"
    rm -f "$tmpfile"

    local balance
    balance=$(check_balance)
    log "MINT" "Mint cycle complete! Balance: ${balance} sats"
    MINT_COUNT=$((MINT_COUNT + 1))
}

do_melt_cycle() {
    local balance amount node add_output payment_request melt_output

    # Step 0: Reconcile any pending proofs before melting
    $CDK_CLI check-pending > /dev/null 2>&1 || true

    # Step 1: Check balance
    balance=$(check_balance)
    if [ "$balance" -lt "$MIN_BALANCE_FOR_SPEND" ]; then
        log "MELT" "Balance too low (${balance} sats), forcing mint cycle instead"
        do_mint_cycle
        return
    fi

    # Pick amount — keep it modest to avoid fee reserve issues
    # Melt requires amount + fee reserve (~5%), so cap conservatively
    local max_melt=$(( balance / 4 ))
    if [ "$max_melt" -gt 200 ]; then
        max_melt=200
    fi
    if [ "$max_melt" -lt "$MIN_AMOUNT" ]; then
        log "MELT" "Balance too low for safe melt, forcing mint cycle instead"
        do_mint_cycle
        return
    fi
    amount=$(random_in_range "$MIN_AMOUNT" "$max_melt")
    node=$(random_invoice_node)

    log "MELT" "Starting melt cycle: ${amount} sats to $node"

    # Step 2: Create an invoice on the LND node
    add_output=$(docker exec "$node" lncli $(lncli_args_for "$node") addinvoice --amt "$amount" 2>&1) || {
        log "ERROR" "Failed to create invoice on $node: $add_output"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    }

    # Parse payment_request — just grab the lnbcrt invoice string directly
    payment_request=$(echo "$add_output" | grep -oE 'lnbcrt[a-zA-Z0-9]+' | head -1)

    if [ -z "$payment_request" ]; then
        log "ERROR" "Could not parse payment_request from addinvoice output: $add_output"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    log "MELT" "Created invoice on $node: ${payment_request:0:40}..."

    # Step 3: Pay the invoice with ecash
    melt_output=$($CDK_CLI melt --mint-url "$MINT_URL" --invoice "$payment_request" 2>&1) || {
        log "ERROR" "Failed to melt: $melt_output"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    }

    log "MELT" "Melt output: $melt_output"

    balance=$(check_balance)
    log "MELT" "Melt cycle complete! Balance: ${balance} sats"
    MELT_COUNT=$((MELT_COUNT + 1))
}

do_swap_cycle() {
    local balance amount send_output token receive_output

    # Step 1: Check balance
    balance=$(check_balance)
    if [ "$balance" -lt "$MIN_BALANCE_FOR_SPEND" ]; then
        log "SWAP" "Balance too low (${balance} sats), forcing mint cycle instead"
        do_mint_cycle
        return
    fi

    # Pick amount (don't exceed balance)
    local max_swap=$(( balance / 2 ))
    if [ "$max_swap" -gt "$MAX_AMOUNT" ]; then
        max_swap=$MAX_AMOUNT
    fi
    if [ "$max_swap" -lt "$MIN_AMOUNT" ]; then
        max_swap=$MIN_AMOUNT
    fi
    amount=$(random_in_range "$MIN_AMOUNT" "$max_swap")

    log "SWAP" "Starting swap cycle: ${amount} sats"

    # Step 2: Send ecash (creates a token)
    send_output=$($CDK_CLI send -a "$amount" --mint-url "$MINT_URL" 2>&1) || {
        log "ERROR" "Failed to send: $send_output"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    }

    # Parse the cashu token from the output
    # Cashu tokens start with "cashuA" (v3) or "cashuB" (v4)
    token=$(echo "$send_output" | grep -oE 'cashu[AB][a-zA-Z0-9_-]+' | head -1)

    if [ -z "$token" ]; then
        log "ERROR" "Could not parse token from send output: $send_output"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    fi

    log "SWAP" "Created token: ${token:0:40}..."

    # Step 3: Receive the token back
    receive_output=$($CDK_CLI receive "$token" 2>&1) || {
        log "ERROR" "Failed to receive: $receive_output"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        return 1
    }

    log "SWAP" "Receive output: $receive_output"

    balance=$(check_balance)
    log "SWAP" "Swap cycle complete! Balance: ${balance} sats"
    SWAP_COUNT=$((SWAP_COUNT + 1))
}

# ---- Main Loop --------------------------------------------------------------

main() {
    log "INFO" "=========================================="
    log "INFO" "  Cashu Mint Activity Simulator Starting"
    log "INFO" "=========================================="
    log "INFO" "Mint URL:      $MINT_URL"
    log "INFO" "Funding node:  $FUNDING_NODE"
    log "INFO" "Invoice node:  $INVOICE_NODE"
    log "INFO" "Backup node:   $BACKUP_NODE"
    log "INFO" "Amount range:  ${MIN_AMOUNT}-${MAX_AMOUNT} sats"
    log "INFO" "Delay range:   ${MIN_DELAY}-${MAX_DELAY}s"
    log "INFO" "Log file:      $LOG_FILE"
    log "INFO" "=========================================="

    # Initial balance check
    local balance
    balance=$(check_balance)
    log "INFO" "Starting balance: ${balance} sats"

    # If starting with 0 balance, do an initial mint
    if [ "$balance" -lt "$MIN_BALANCE_FOR_SPEND" ]; then
        log "INFO" "Low starting balance, performing initial mint..."
        do_mint_cycle
    fi

    while true; do
        # Weighted random selection: 40% mint, 30% melt, 30% swap
        local roll=$(( RANDOM % 100 ))

        if [ $roll -lt 40 ]; then
            do_mint_cycle
        elif [ $roll -lt 70 ]; then
            do_melt_cycle
        else
            do_swap_cycle
        fi

        random_delay

        # Periodic summary every 20 operations
        local total=$(( MINT_COUNT + MELT_COUNT + SWAP_COUNT ))
        if [ $(( total % 20 )) -eq 0 ] && [ "$total" -gt 0 ]; then
            print_summary
        fi
    done
}

# ---- Subcommand Dispatch ----------------------------------------------------
# Supports: (no args) = main loop, balance, mint <amt>, melt <amt>, swap <amt>

case "${1:-run}" in
    balance)
        check_balance
        ;;
    mint)
        amount="${2:-$(random_amount)}"
        MIN_AMOUNT="$amount"
        MAX_AMOUNT="$amount"
        do_mint_cycle
        ;;
    melt)
        amount="${2:-$(random_amount)}"
        MIN_AMOUNT="$amount"
        MAX_AMOUNT="$amount"
        do_melt_cycle
        ;;
    swap)
        amount="${2:-$(random_amount)}"
        MIN_AMOUNT="$amount"
        MAX_AMOUNT="$amount"
        do_swap_cycle
        ;;
    run|*)
        main
        ;;
esac
