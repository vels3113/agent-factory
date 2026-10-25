#!/usr/bin/env bash
# Run the test suites. Each runs in its own sandbox (tests/lib.sh); the first
# run downloads OpenCode into a cache folder.
# Usage: tests/run.sh [--model]
#   --model  also run tests/agent-model.sh (real model calls; see that file)
set -uo pipefail

dir="$(dirname "$0")"
suites=(opencode-behavior.sh task-workflow.sh model-suggest.sh)
[[ "${1:-}" == --model ]] && suites+=(agent-model.sh)

failed=()
for s in "${suites[@]}"; do
    echo "=== $s"
    "$dir/$s" || failed+=("$s")
done
echo
if [[ ${#failed[@]} -eq 0 ]]; then
    echo "All suites passed."
else
    echo "Failed: ${failed[*]}"
    exit 1
fi
