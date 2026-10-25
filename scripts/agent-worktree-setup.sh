#!/usr/bin/env bash
# Run by OpenCode inside every worktree it creates (the project's commands.start,
# registered by bootstrap/08-task-workflow.sh), whether agent-task.sh or an
# agent asked for it. The worktree arrives on a detached HEAD; this puts it on
# branch agent/<id> from origin/<base> and records it in the task journal.
# Rejects (removes) worktrees whose name is not a task ID.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/agent-lib.sh"

wt="${OPENCODE_WORKTREE_PATH:?Run by OpenCode after creating a worktree}"
main="${OPENCODE_WORKTREE_BASE:?Run by OpenCode after creating a worktree}"
id="$(basename "$wt")"

reject() {
    echo "$1" >&2
    git -C "$main" worktree remove --force "$wt" || true
    exit 1
}

valid_id "$id" || reject "Worktree name '$id' is not a task ID (TASK-<n> or VM-<n>)."
if [[ "$id" == VM-* ]] && ! task_known "$id"; then
    reject "$id is not in the journal; get a new ID with: agent-task.sh new \"<title>\""
fi

project_env="$(dirname "$main")/agent.env"
[[ -r "$project_env" ]] || reject "Missing $project_env; run bootstrap/08-task-workflow.sh."
source "$project_env"

branch="agent/$id"
git -C "$wt" fetch -q origin "$BASE_BRANCH" || reject "git fetch origin $BASE_BRANCH failed."
if git -C "$wt" show-ref --verify -q "refs/heads/$branch"; then
    git -C "$wt" switch -q "$branch" || reject "Cannot switch to existing $branch (checked out elsewhere?)."
    how="existing branch $branch"
else
    # --no-track: never push to the base branch by accident.
    git -C "$wt" switch -q --no-track -c "$branch" "origin/$BASE_BRANCH"
    how="new branch $branch from origin/$BASE_BRANCH"
fi

task_known "$id" || add_task "$id"
log_event "$id" "worktree $wt on $how ($(git -C "$wt" rev-parse --short HEAD))"
set_status "$id" active
