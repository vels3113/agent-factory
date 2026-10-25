#!/usr/bin/env bash
# Suggest OpenRouter models per agent tier from the OpenRouter catalog and the
# task ledger; prints a shortlist per tier and agents.<name>.model lines to paste
# into <project>/opencode.jsonc. Never edits the config. Design: model-suggest-design.md.
# Usage: model-suggest.sh
# Settings (env):
#   MODEL_SUGGEST_MIX          reference task tokens: cache read,input,cache write,output
#                              (default 2000000,300000,0,50000)
#   MODEL_SUGGEST_FLOOR_MAIN   intelligence_index floor, main tier: a number, or p<N> for
#                              the N-th percentile of the rated candidates (default p90)
#   MODEL_SUGGEST_FLOOR_CHEAP  same, cheap tier (default p50)
#   MODEL_SUGGEST_TOP          rows per tier (default 5)
#   MODEL_SUGGEST_MIN_CTX      minimum context length (default 128000)
#   MODEL_SUGGEST_CATALOG      read the catalog from this file instead of the API
set -euo pipefail
here="$(dirname "$(readlink -f "$0")")"
source "$here/agent-lib.sh"

ledger="$factory_dir/ledger.csv"
[[ -r "$ledger" ]] || { echo "Missing $ledger; run bootstrap/02-init-ledger.sh." >&2; exit 1; }
config=""
if [[ -r "$factory_dir/vm.env" ]]; then
    config="$(source "$factory_dir/vm.env" && echo "${PROJECT_DIR:-}/opencode.jsonc")"
fi
if [[ ! -r "$config" ]]; then
    echo "Note: no project opencode.jsonc found (bootstrap/03-project-layout.sh, then 04-vm-facts.sh); current models not shown." >&2
    config=""
fi
exec python3 -I "$here/model_suggest.py" "$ledger" "$config"
