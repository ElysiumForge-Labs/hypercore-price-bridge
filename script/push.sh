#!/usr/bin/env bash
# Sends fresh HyperCore prices to Elysium by calling Beacon.push() on HyperEVM.
#
# Optional: anyone can call push() from any wallet, and the Beacon reads the prices
# itself. This script only works out the fees.
#
# What one push pays for, all in HYPE on HyperEVM:
#   - a submission fee, so Elysium accepts the message (quoted by Elysium's Inbox)
#   - the Elysium gas that runs Receiver.update() when the message lands
# Anything left over is refunded to the sender's address on Elysium.
#
# Needs Foundry (cast) and jq.
#
# Usage:
#   HYPEREVM_RPC=... ELYSIUM_RPC=... BEACON=0x... PERPS=0,1 script/push.sh
#   INTERVAL=60 ... script/push.sh      # push again every 60 seconds
#
# Signing uses cast's own keystore settings, so the key never appears here:
#   ETH_KEYSTORE          path to a keystore file, or
#   ETH_KEYSTORE_ACCOUNT  name of a key in ~/.foundry/keystores (cast wallet new <name>)
#   ETH_PASSWORD          optional: path to a file holding its password, else cast asks
#
# Any failed step stops the script. Nothing is retried or skipped quietly.
set -euo pipefail

# Both fees can rise between quoting and the transaction landing. Paying double
# covers that; the unused part comes back as the refund above.
FEE_MARGIN=2
# The gas estimate is for Elysium's state right now. Add half again for safety.
GAS_MARGIN_PERCENT=150

UPDATE_SIG="update(uint32[],uint64[],uint64,uint64)"

die() {
    echo "push: $*" >&2
    exit 1
}

need() {
    [[ -n "${!1:-}" ]] || die "set $1"
}

# Bash integers stop at ~9.2e18 wei (~9.2 HYPE). A push never costs that much,
# so a result past it means a wrong quote: stop rather than wrap around.
mul() {
    local product=$(($1 * $2))
    [[ $1 -eq 0 || $((product / $1)) -eq $2 ]] || die "fee overflow: $1 * $2"
    echo "$product"
}

hyperevm() { cast "$@" --rpc-url "$HYPEREVM_RPC"; }
elysium() { cast "$@" --rpc-url "$ELYSIUM_RPC"; }

push_once() {
    local perps="[$PERPS]"

    # The Beacon knows both addresses, so nothing else needs configuring.
    local inbox receiver
    inbox=$(hyperevm call "$BEACON" "inbox()(address)")
    receiver=$(hyperevm call "$BEACON" "receiver()(address)")

    # What push() would send right now. Used only to size the fees.
    # --json, because cast's plain output adds notes like "815959 [8.159e5]".
    local reading prices hyperCoreBlock
    reading=$(hyperevm call "$BEACON" "read(uint32[])(uint64[],uint64)" "$perps" --json)
    prices=$(jq -ecr '.[0]' <<<"$reading")
    hyperCoreBlock=$(jq -er '.[1]' <<<"$reading")

    # Elysium gas for Receiver.update(), estimated as the bridge would run it: from
    # the Beacon's shifted address, which the Receiver stores as beacon(). The real
    # read time is not known yet; any past time costs about the same gas, and the
    # margin below covers the difference.
    # The keystore settings are dropped here: with them set, cast estimates as the
    # signer and ignores --from, and the Receiver refuses the signer.
    local sender gas gasLimit
    sender=$(elysium call "$receiver" "beacon()(address)")
    gas=$(env -u ETH_KEYSTORE -u ETH_KEYSTORE_ACCOUNT -u ETH_PASSWORD \
        cast estimate --rpc-url "$ELYSIUM_RPC" --from "$sender" "$receiver" "$UPDATE_SIG" \
        "$perps" "$prices" "$hyperCoreBlock" 1)
    gasLimit=$((gas * GAS_MARGIN_PERCENT / 100))

    local maxFeePerGas
    maxFeePerGas=$(mul "$(elysium gas-price)" "$FEE_MARGIN")

    # The submission fee depends on the message size and on HyperEVM's base fee.
    local message bytes baseFee submissionFee
    message=$(cast calldata "$UPDATE_SIG" "$perps" "$prices" "$hyperCoreBlock" 1)
    bytes=$(((${#message} - 2) / 2))
    baseFee=$(mul "$(hyperevm base-fee)" "$FEE_MARGIN")
    submissionFee=$(hyperevm call "$inbox" \
        "calculateRetryableSubmissionFee(uint256,uint256)(uint256)" "$bytes" "$baseFee" --json \
        | jq -er '.[0]')

    local gasCost value
    gasCost=$(mul "$gasLimit" "$maxFeePerGas")
    value=$((submissionFee + gasCost))
    [[ $value -ge $gasCost ]] || die "fee overflow adding the submission fee"

    # With --json, cast reports its own errors on stdout, not stderr, so pull the
    # message out of its reply or it is lost.
    local result tx
    result=$(hyperevm send "$BEACON" "push(uint32[],uint256,uint256)" \
        "$perps" "$gasLimit" "$maxFeePerGas" --value "$value" --json) \
        || die "push not sent: $(jq -r '.errors[]?.message' <<<"$result")"
    tx=$(jq -er 'select(.status == "0x1") | .transactionHash' <<<"$result") \
        || die "push reverted: $(jq -r '.transactionHash' <<<"$result")"

    echo "$(date -u +%FT%TZ) pushed HyperCore block $hyperCoreBlock perps $perps" \
        "paid $value wei tx $tx"
}

need HYPEREVM_RPC
need ELYSIUM_RPC
need BEACON
need PERPS

push_once
while [[ -n "${INTERVAL:-}" ]]; do
    sleep "$INTERVAL"
    push_once
done
