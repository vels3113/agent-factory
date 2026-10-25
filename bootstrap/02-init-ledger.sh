#!/usr/bin/env bash
# Create the task ledger CSV. Never overwrites an existing ledger.
set -euo pipefail
source "$(dirname "$0")/../scripts/agent-lib.sh"

ledger="$factory_dir/ledger.csv"
mkdir -p "$factory_dir"

if [[ -s "$ledger" ]]; then
    echo "Ledger exists: $ledger (left unchanged)."
    [[ "$(head -n 1 "$ledger")" == "$ledger_header" ]] \
        || echo "WARNING: its columns differ from this version's; move it aside and rerun to start a new one." >&2
    exit 0
fi

echo "$ledger_header" > "$ledger"
echo "Created $ledger"
echo "  mode: interactive | background"
echo "  origin: new | replayed"
echo "  outcome: accepted | reworked | failed"
