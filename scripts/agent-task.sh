#!/usr/bin/env bash
# Agent task lifecycle: one worktree and branch agent/<id> per task, with an
# agent task journal. Task IDs: TASK-<n> (Taiga) or VM-<n> (local, numbered here).
# Usage:
#   agent-task.sh new "<title>" [--parent <id>]   allocate a VM-<n> task, print its ID
#   agent-task.sh start <id> ["<title>"]          create or reopen the worktree, open OpenCode in it
#   agent-task.sh start --new "<title>" [--parent <id>]
#   agent-task.sh done <id>                       archive the report, remove the worktree and
#                                                 the branch (kept if it has unpushed commits)
#   agent-task.sh list                            print the journal index
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/agent-lib.sh"

usage() { sed -n '5,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }

load_project() {
    local env="$factory_dir/vm.env"
    [[ -r "$env" ]] || { echo "Missing $env; run bootstrap/04-vm-facts.sh." >&2; exit 1; }
    source "$env"
    main="$PROJECT_DIR/main"
    worktrees="$PROJECT_DIR/worktrees"
}

# new_task <title> [--parent <id>]: prints the new ID.
new_task() {
    local title="${1:-}" parent=""
    [[ -n "$title" ]] || usage
    shift
    if [[ "${1:-}" == --parent ]]; then
        parent="${2:?--parent needs a task ID}"
        valid_id "$parent" || { echo "Bad parent ID: $parent" >&2; exit 1; }
    fi
    init_journal
    exec 9>"$index.lock"
    flock 9
    local id
    id="$(next_vm_id)"
    add_task "$id" "$title" "$parent"
    flock -u 9
    if [[ -n "$parent" ]] && task_known "$parent"; then
        log_event "$parent" "side task [$id]($id.md): $title"
    fi
    echo "$id"
}

start_task() {
    local id="${1:-}"
    [[ -n "$id" ]] || usage
    if [[ "$id" == --new ]]; then
        shift
        id="$(new_task "$@")"
    else
        valid_id "$id" || { echo "Not a task ID: $id (TASK-<n> or VM-<n>)" >&2; exit 1; }
        init_journal
        if ! task_known "$id"; then
            [[ "$id" == TASK-* ]] || { echo "$id is not in the journal; use: agent-task.sh new" >&2; exit 1; }
            add_task "$id" "${2:-}"
        fi
    fi
    load_project
    local wt="$worktrees/$id" pid out
    if [[ -d "$wt" ]]; then
        log_event "$id" "session reopened"
    else
        pid="$(project_id "$main")"
        out="$(cd "$main" && opencode api --standalone worktree.create \
            -d "{\"projectID\":\"$pid\",\"name\":\"$id\"}")" \
            || { echo "Worktree creation failed: $out" >&2; exit 1; }
        [[ -d "$wt" ]] || { echo "Unexpected worktree location: $out" >&2; exit 1; }
    fi
    echo "Task $id: $wt (branch $(git -C "$wt" branch --show-current))"
    opencode "$wt" || true
    archive_report "$id" "$wt" session
    log_event "$id" "session ended"
}

done_task() {
    local id="${1:-}"
    valid_id "$id" || usage
    task_known "$id" || { echo "$id is not in the journal." >&2; exit 1; }
    load_project
    local wt="$worktrees/$id" branch="agent/$id" pid
    if [[ -d "$wt" && -n "$(git -C "$wt" status --porcelain)" ]]; then
        echo "$wt has uncommitted changes; commit or discard them first." >&2
        exit 1
    fi
    # One ledger row per finished task; a rerun after a failed removal adds none.
    if ! grep -q "^| \[$id\](.* | done |$" "$index"; then
        local origin human outcome notes
        read -r -p "Origin (new/replayed) [new]: " origin || true
        read -r -p "Your hands-on minutes: " human || true
        until [[ "${outcome:-}" =~ ^(accepted|reworked|failed)$ ]]; do
            read -r -p "Outcome (accepted/reworked/failed): " outcome || exit 1
        done
        read -r -p "Notes (optional): " notes || true
        # Mode: interactive until the background loop passes its own.
        ledger_row "$main" "$wt" "$id" interactive "${origin:-new}" "$human" "$outcome" "$notes"
        log_event "$id" "ledger row: $outcome"
    fi
    if [[ -d "$wt" ]]; then
        archive_report "$id" "$wt" final
        pid="$(project_id "$main")"
        (cd "$main" && opencode api --standalone worktree.remove \
            -d "{\"projectID\":\"$pid\",\"directory\":\"$wt\",\"force\":false}") >/dev/null
        log_event "$id" "worktree removed"
    fi
    if git -C "$main" show-ref --verify -q "refs/heads/$branch"; then
        if [[ -z "$(git -C "$main" log --oneline "$branch" --not --remotes)" ]]; then
            git -C "$main" branch -q -D "$branch"
            log_event "$id" "local branch $branch deleted"
        else
            echo "Kept $branch: it has commits that are on no remote." >&2
            log_event "$id" "local branch $branch kept (unpushed commits)"
        fi
    fi
    set_status "$id" done
    echo "Task $id done. Journal: $journal_dir/$id.md"
}

case "${1:-}" in
    new) shift; new_task "$@" ;;
    start) shift; start_task "$@" ;;
    done) shift; done_task "$@" ;;
    list) cat "$index" 2>/dev/null || echo "No tasks yet." ;;
    *) usage ;;
esac
