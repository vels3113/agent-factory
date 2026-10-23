#!/usr/bin/env bash
# Create the task ledger CSV. Never overwrites an existing ledger.
set -euo pipefail

work_dir="${AGENT_FACTORY_DIR:-$HOME/.agent-factory}"
ledger="$work_dir/ledger.csv"
header="task_id,date,mode,origin,model,provider,session_id,api_cost_usd,agent_minutes,human_minutes,local_check_rounds,jenkins_rounds,build_minutes,disk_used_gb,outcome,notes"

mkdir -p "$work_dir"

if [[ -s "$ledger" ]]; then
    echo "Ledger exists: $ledger (left unchanged)."
    exit 0
fi

echo "$header" > "$ledger"
echo "Created $ledger"
echo "  mode: interactive | background"
echo "  origin: new | replayed"
echo "  outcome: accepted | reworked | failed"
