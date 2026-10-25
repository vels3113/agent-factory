#!/usr/bin/env bash
# The task workflow scripts end to end, against real OpenCode but without a
# model: bootstrap/08-task-workflow.sh, scripts/agent-task.sh, the worktree
# setup hook, the journal, report archive and ledger. The interactive UI is a
# stub that writes a report and exits (tests/lib.sh).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
sandbox
make_layout
source "$REPO/scripts/agent-lib.sh"
journal="$HOME/.agent-factory/journal"
ledger="$HOME/.agent-factory/ledger.csv"
ledger_field() { python3 -I -c 'import csv,sys; print(list(csv.reader(open(sys.argv[1])))[int(sys.argv[2])][int(sys.argv[3])])' "$ledger" "$1" "$2"; }

echo "# 08-task-workflow.sh"
check "08 runs" "$REPO/bootstrap/08-task-workflow.sh" "$P" lemon
check "08 is idempotent" bash -c "'$REPO/bootstrap/08-task-workflow.sh' '$P' lemon | grep -q 'start command already set'"
check_eq "agent.env has the base branch" "BASE_BRANCH=lemon" "$(cat "$P/agent.env")"
check ".agent/ in info/exclude" grep -qx '.agent/' "$MAIN/.git/info/exclude"
check "agent-task.sh on PATH" command -v agent-task.sh
check "08 rejects a missing base branch" bash -c "! '$REPO/bootstrap/08-task-workflow.sh' '$P' no-such-branch"

echo "# start"
check "start TASK-1" agent-task.sh start TASK-1 "First task"
wt="$P/worktrees/TASK-1"
check_eq "worktree on agent/TASK-1" "agent/TASK-1" "$(git -C "$wt" branch --show-current)"
check "branch has no upstream" bash -c "! git -C '$wt' rev-parse --abbrev-ref '@{u}'"
check_eq "branch starts at origin/lemon" "$(git -C "$MAIN" rev-parse origin/lemon)" "$(git -C "$wt" rev-parse HEAD)"
check "index row: taiga, active" bash -c "grep -q '^| \[TASK-1\](TASK-1.md) | taiga |  | First task | active |$' '$journal/index.md'"
check ".agent/ ignored by git status" test -z "$(mkdir -p "$wt/.agent"; touch "$wt/.agent/x"; git -C "$wt" status --porcelain)"
rm -rf "$wt/.agent"
agent-task.sh start TASK-1 >/dev/null
check_eq "reopen archives each session's report separately" 2 "$(ls "$HOME/.agent-factory/reports/TASK-1" | wc -l)"
check "journal links the reports" grep -q 'report: \[.*\](../reports/TASK-1/' "$journal/TASK-1.md"

echo "# local tasks"
check_eq "new allocates VM-0001" "VM-0001" "$(agent-task.sh new "Side bug" --parent TASK-1)"
check "new is logged in the parent's journal" grep -q 'side task \[VM-0001\]' "$journal/TASK-1.md"
check "start --new allocates and starts VM-0002" agent-task.sh start --new "Second"
check_eq "VM-0002 on its branch" "agent/VM-0002" "$(git -C "$P/worktrees/VM-0002" branch --show-current)"

echo "# rejections"
check "start rejects a non-ID" bash -c "! agent-task.sh start foo"
check "start rejects an unallocated VM ID" bash -c "! agent-task.sh start VM-0099"
pid="$(project_id "$MAIN")"
for name in random-name VM-0099; do
    check "hook rejects worktree '$name' created through OpenCode" bash -c "! (cd '$MAIN' && timeout $OC_TIMEOUT opencode api --standalone worktree.create -d '{\"projectID\":\"$pid\",\"name\":\"$name\"}') >/dev/null 2>&1"
    check "hook removes rejected worktree '$name'" test ! -d "$P/worktrees/$name"
done

echo "# done and ledger"
touch "$wt/dirty"
check "done refuses uncommitted changes" bash -c "! agent-task.sh done TASK-1 </dev/null"
rm "$wt/dirty"
git -C "$wt" commit -q --allow-empty -m "local work"
check "done TASK-1" bash -c "printf 'new\n7\nmaybe\naccepted\nnote, with comma\n' | agent-task.sh done TASK-1"
check "worktree removed" test ! -d "$wt"
check "branch with unpushed commits kept" git -C "$MAIN" show-ref -q --verify refs/heads/agent/TASK-1
check "index status done" grep -q '^| \[TASK-1\](.* | done |$' "$journal/index.md"
check_eq "ledger has one row" 2 "$(wc -l < "$ledger")"
check_eq "ledger: 16 columns" 16 "$(python3 -I -c 'import csv,sys; print(len(list(csv.reader(open(sys.argv[1])))[1]))' "$ledger")"
check_eq "ledger: task, mode, origin" "TASK-1 interactive new" "$(ledger_field 1 0) $(ledger_field 1 2) $(ledger_field 1 3)"
check_eq "ledger: human minutes, outcome (bad answer re-asked)" "7 accepted" "$(ledger_field 1 9) $(ledger_field 1 14)"
check_eq "ledger: notes with a comma" "note, with comma" "$(ledger_field 1 15)"
agent-task.sh done TASK-1 </dev/null >/dev/null 2>&1
check_eq "rerunning done adds no row" 2 "$(wc -l < "$ledger")"
check "done VM-0002" bash -c "printf '\n\nfailed\n\n' | agent-task.sh done VM-0002"
check "branch without new commits deleted" bash -c "! git -C '$MAIN' show-ref -q --verify refs/heads/agent/VM-0002"

echo "# restart"
check "restart a done task" agent-task.sh start TASK-1
check "restart reuses the existing branch" grep -q 'on existing branch agent/TASK-1' "$journal/TASK-1.md"
check_eq "restarted task keeps its commits" "local work" "$(git -C "$wt" log -1 --format=%s)"

finish
