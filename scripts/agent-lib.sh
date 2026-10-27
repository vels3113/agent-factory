# Shared helpers for the agent task scripts; sourced, not run.
# Task IDs: TASK-<n> (Taiga) or VM-<n> (local: CI-unrelated bugs, side tasks).
# Journal: $AGENT_FACTORY_DIR/journal/index.md (one row per task) and
# journal/<id>.md (append-only events). Reports are archived under reports/<id>/
# and linked from the journal, never pasted into it.

factory_dir="${AGENT_FACTORY_DIR:-$HOME/.agent-factory}"
lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # with ledger_row.py and opencode_json.py
journal_dir="$factory_dir/journal"
reports_dir="$factory_dir/reports"
index="$journal_dir/index.md"

valid_id() { [[ "$1" =~ ^(TASK|VM)-[0-9]+$ ]]; }

init_journal() {
    mkdir -p "$journal_dir" "$reports_dir"
    [[ -e "$index" ]] || printf '# Agent task journal\n\n| Task | Source | Parent | Title | Status |\n| --- | --- | --- | --- | --- |\n' > "$index"
}

task_known() { grep -q "^| \[$1\](" "$index" 2>/dev/null; }

log_event() { printf -- '- %s %s\n' "$(date '+%F %H:%M')" "$2" >> "$journal_dir/$1.md"; }

# add_task <id> [title] [parent]
add_task() {
    local id="$1" title="${2:-}" parent="${3:-}" source=local
    [[ "$id" == TASK-* ]] && source=taiga
    title="${title//$'\n'/ }"; title="${title//|//}"
    init_journal
    printf '| [%s](%s.md) | %s | %s | %s | open |\n' "$id" "$id" "$source" "$parent" "$title" >> "$index"
    printf '# %s%s\n\n- Source: %s%s\n- Branch: agent/%s\n\n## Events\n\n' \
        "$id" "${title:+: $title}" "$source" "${parent:+, parent $parent}" "$id" > "$journal_dir/$id.md"
    log_event "$id" "created"
}

set_status() {
    local tmp
    tmp="$(mktemp)"
    awk -v id="| [$1](" -v st="$2" 'index($0, id) == 1 { sub(/\| [^|]* \|$/, "| " st " |") } { print }' "$index" > "$tmp"
    cat "$tmp" > "$index"; rm -f "$tmp"
}

next_vm_id() {
    local n
    n="$(grep -o '^| \[VM-[0-9]*\]' "$index" 2>/dev/null | grep -o '[0-9]*' | sort -n | tail -n 1)"
    printf 'VM-%04d\n' "$(( 10#${n:-0} + 1 ))"
}

# archive_report <id> <worktree> <label>: move .agent/report.md to the archive
# and link it from the task journal.
archive_report() {
    local src="$2/.agent/report.md" name n=1
    [[ -s "$src" ]] || return 0
    name="$(date '+%Y%m%d-%H%M%S')-$3.md"
    mkdir -p "$reports_dir/$1"
    while [[ -e "$reports_dir/$1/$name" ]]; do name="$(date '+%Y%m%d-%H%M%S')-$3-$((++n)).md"; done
    mv "$src" "$reports_dir/$1/$name"
    log_event "$1" "report: [$name](../reports/$1/$name)"
}

# Ledger columns, written as the header by bootstrap/02-init-ledger.sh. Only data
# on the model's work; build times and disk use go to the task journal.
ledger_header="task_id,date,mode,origin,model,provider,session_id,api_cost_usd,agent_minutes,human_minutes,local_check_rounds,local_check_failures,jenkins_rounds,outcome,notes"

# ledger_row <main-checkout> <worktree> <id> <mode> <origin> <human-min> <outcome> <notes>:
# append one row to ledger.csv. Model, cost, sessions and agent minutes come from
# the OpenCode sessions that ran in the worktree. Agent minutes are the model's
# working time: from each prompt or background-command wake-up to idle, minus
# the time inside tool calls. In 2.1.3 a tool call's time includes the wait at
# its approval prompt, so the human's wait is never counted. Check rounds come
# from journal/<id>.checks.tsv, counting only rows OpenCode ran: agent-check.sh
# checks (failed: exit 1, 2 or 5) and the build and test commands the plugin
# wrapped (failed: any non-zero exit). Jenkins rounds stay empty until that
# script exists. Cost: what the provider charged, from the plugin's costs.tsv
# rows for these sessions; a session without rows (no plugin, or a provider
# that reports no cost) counts with OpenCode's estimate from list prices, and
# the notes say so.
ledger_row() {
    local main="$1" wt="$2" ledger="$factory_dir/ledger.csv" sessions
    [[ -s "$ledger" ]] || { echo "No ledger at $ledger; run bootstrap/02-init-ledger.sh." >&2; return 1; }
    [[ "$(head -n 1 "$ledger")" == "$ledger_header" ]] \
        || { echo "$ledger has older columns; move it aside and run bootstrap/02-init-ledger.sh." >&2; return 1; }
    sessions="$(mktemp -d)"
    (cd "$main" && opencode session list --standalone --format json -n 1000) > "$sessions/list.json"
    python3 -I "$lib_dir/opencode_json.py" sessions-in "$wt" < "$sessions/list.json" |
    while read -r sid; do
        (cd "$main" && opencode session export --standalone "$sid") > "$sessions/$sid.json"
    done
    rm -f "$sessions/list.json"
    python3 -I "$lib_dir/ledger_row.py" "$ledger" "$sessions" "$journal_dir/$3.checks.tsv" "$factory_dir/costs.tsv" "$3" "$4" "$5" "$6" "$7" "$8"
    rm -rf "$sessions"
}

# project_id <main-checkout>: OpenCode's project ID for the repo.
project_id() {
    local main
    main="$(cd "$1" && pwd -P)"
    (cd "$main" && opencode api --standalone project.list) | python3 -I "$lib_dir/opencode_json.py" project-id "$main"
}
