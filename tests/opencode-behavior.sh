#!/usr/bin/env bash
# OpenCode behavior the scripts rely on but the v2 docs don't state (or state
# only partly). Run before changing the pinned version:
#   OPENCODE_VERSION=2.x.y tests/opencode-behavior.sh
# No model needed.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
sandbox
make_layout
source "$REPO/scripts/agent-lib.sh"

echo "# OpenCode $OC_VERSION"
check_eq "installed version" "opencode v$OC_VERSION" "$(opencode --version)"

# Project config is found in the parent folder, from the repo and from worktrees.
config_sources() { (cd "$1" && timeout "$OC_TIMEOUT" opencode debug config); }
check "project config loaded from main/" grep -q "$P/opencode.jsonc" <(config_sources "$MAIN")
git -C "$MAIN" worktree add -q --detach "$P/worktrees/plain"
check "project config loaded from a worktree" grep -q "$P/opencode.jsonc" <(config_sources "$P/worktrees/plain")
agents="$(config_sources "$MAIN" | python3 -I -c '
import json, sys
docs = [s for s in json.load(sys.stdin) if s.get("path", "").endswith("/demo/opencode.jsonc")]
print(" ".join(sorted(docs[0]["info"]["agents"])))')"
check_eq "template parses: agents" "build ci-fix explore plan" "$agents"
git -C "$MAIN" worktree remove "$P/worktrees/plain"

# Project ID lookup through the API (used by agent-task.sh and 08-task-workflow.sh).
pid="$(project_id "$MAIN")"
check "project.list returns the project" test -n "$pid"
check "API errors exit non-zero" bash -c "! (cd '$MAIN' && timeout $OC_TIMEOUT opencode api --standalone worktree.create -d '{\"projectID\":\"nope\",\"name\":\"x\"}') >/dev/null 2>&1"

# worktree.create: location from "worktree.directory", detached HEAD, start command.
probe="$T/start-probe.txt"
oc_api project.update --param "projectID=$pid" \
    -d "{\"commands\":{\"start\":\"{ pwd; echo \$OPENCODE_WORKTREE_BASE; echo \$OPENCODE_WORKTREE_PATH; } > $probe\"}}" >/dev/null
out="$(oc_api worktree.create -d "{\"projectID\":\"$pid\",\"name\":\"probe\"}")"
wt="$P/worktrees/probe"
check "worktree.create uses worktree.directory (../worktrees/<name>)" test -d "$wt"
check "worktree.create returns the directory" grep -q "\"directory\":\"$wt\"" <<<"$out"
check "new worktree is on a detached HEAD" bash -c "! git -C '$wt' symbolic-ref -q HEAD"
check_eq "start command runs inside the worktree" "$wt" "$(sed -n 1p "$probe" 2>/dev/null)"
check_eq "start command gets OPENCODE_WORKTREE_BASE" "$(cd "$MAIN" && pwd -P)" "$(sed -n 2p "$probe" 2>/dev/null)"
check_eq "start command gets OPENCODE_WORKTREE_PATH" "$wt" "$(sed -n 3p "$probe" 2>/dev/null)"

out="$(oc_api worktree.create -d "{\"projectID\":\"$pid\",\"name\":\"probe\"}")"
check "name collision gets a -2 suffix" grep -q "\"directory\":\"$wt-2\"" <<<"$out"

check "branch input is a starting ref, not a new branch" bash -c "! (cd '$MAIN' && timeout $OC_TIMEOUT opencode api --standalone worktree.create -d '{\"projectID\":\"$pid\",\"name\":\"b\",\"branch\":\"agent/new\"}') >/dev/null 2>&1"

oc_api project.update --param "projectID=$pid" -d '{"commands":{"start":"exit 3"}}' >/dev/null
check "failing start command fails worktree.create" bash -c "! (cd '$MAIN' && timeout $OC_TIMEOUT opencode api --standalone worktree.create -d '{\"projectID\":\"$pid\",\"name\":\"bad\"}') >/dev/null 2>&1"
check "failing start command leaves the worktree (setup script must remove it)" test -d "$P/worktrees/bad"

oc_api worktree.remove -d "{\"projectID\":\"$pid\",\"directory\":\"$wt-2\",\"force\":false}" >/dev/null
check "worktree.remove deletes the worktree" test ! -d "$wt-2"

# Session list JSON (the ledger matches sessions to a task by directory).
check "session list --format json is a JSON array" bash -c "(cd '$MAIN' && timeout $OC_TIMEOUT opencode session list --standalone --format json) | python3 -I -c 'import json,sys; assert isinstance(json.load(sys.stdin), list)'"

finish
