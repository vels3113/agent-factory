#!/usr/bin/env bash
# Agent behavior with a real model: OpenCode's worktree tools, the rules in
# templates/AGENTS.md, and a ledger row built from real sessions. Results depend
# on the model, so a failure here means "check by hand", not necessarily a bug.
#   AGENT_TEST_MODEL   model to use (default: opencode/glm-5.3-flash-free, free
#                      and zero-retention; no sign-in needed)
set -uo pipefail
source "$(dirname "$0")/lib.sh"
MODEL="${AGENT_TEST_MODEL:-opencode/glm-5.3-flash-free}"
sandbox
make_layout
"$REPO/bootstrap/08-task-workflow.sh" "$P" lemon >/dev/null
journal="$HOME/.agent-factory/journal"
ledger="$HOME/.agent-factory/ledger.csv"
echo "# model $MODEL"

# agent_run <dir> <prompt>: one non-interactive run with permissions approved.
# Retries once: free endpoints sometimes stall without any output.
agent_run() {
    local attempt
    for attempt in 1 2; do
        (cd "$1" && timeout 300 opencode run --standalone --auto -m "$MODEL" "$2") > "$T/run.out" 2>&1 && return 0
        echo "  (run attempt $attempt failed or timed out)"
    done
    return 1
}

echo "# worktree_create + session_move"
id="$(agent-task.sh new "Worktree tool probe")"
wt="$P/worktrees/$id"
agent_run "$MAIN" "Create a worktree named $id with the worktree_create tool, move this session into it with session_move, then run the shell command pwd. Do nothing else."
check "agent created worktree $id" test -d "$wt"
check_eq "hook put the agent's worktree on agent/$id" "agent/$id" "$(git -C "$wt" branch --show-current 2>/dev/null)"
check "session moved into the worktree" bash -c "(cd '$MAIN' && opencode session list --standalone --format json) | python3 -I -c 'import json,sys; assert any(s.get(\"directory\") == sys.argv[1] for s in json.load(sys.stdin))' '$wt'"

echo "# AGENTS.md rules"
agent-task.sh start TASK-2 "Rules probe" >/dev/null
wt="$P/worktrees/TASK-2"
rm -rf "$wt/.agent"
printf 'int average(int *v, int n) {\n    int s = 0;\n    for (int i = 0; i < n; i++) s += v[i];\n    return s / n;\n}\n' > "$wt/util.c"
git -C "$wt" add util.c && git -C "$wt" commit -q -m "add util.c"
agent_run "$wt" "Task: create math.c with a function int add(int a, int b) that returns a + b, and commit it. agent-check.sh is not available in this test, so skip the check. While reading util.c you will notice that average() divides by zero when n == 0; that is outside this task."
check "math.c committed" git -C "$wt" cat-file -e HEAD:math.c
check "out-of-scope util.c left unchanged" git -C "$wt" diff --quiet HEAD~1 HEAD -- util.c
check "side task filed with parent TASK-2" grep -q '^| \[VM-[0-9]*\](.*) | local | TASK-2 |' "$journal/index.md"
check "report written to .agent/report.md" test -s "$wt/.agent/report.md"
check "report names the side task" grep -q 'VM-[0-9]' "$wt/.agent/report.md"

echo "# ledger from real sessions"
printf '#!/bin/sh\necho "check ok"\n' > "$T/bin/agent-check.sh"
chmod +x "$T/bin/agent-check.sh"
agent_run "$wt" "Run the local check twice, as two separate shell commands, then stop. Don't change any files."
printf 'new\n5\naccepted\n\n' | agent-task.sh done TASK-2 >/dev/null 2>&1
fields="$(python3 -I -c '
import csv, sys
r = list(csv.reader(open(sys.argv[1])))[-1]
print(r[0], r[4], r[5], len(r[6].split()), r[8], r[10])' "$ledger")"
read -r task model provider sessions minutes checks <<<"$fields"
check_eq "ledger row for TASK-2" TASK-2 "$task"
check_eq "ledger model" "${MODEL#*/}" "$model"
check_eq "ledger provider" "${MODEL%%/*}" "$provider"
check_eq "ledger counts both sessions" 2 "$sessions"
check "ledger agent minutes > 0" python3 -I -c "assert float('$minutes') > 0"
check "ledger counts check rounds" test "$checks" -ge 1

finish
