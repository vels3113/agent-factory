# Shared helpers for the agent task scripts; sourced, not run.
# Task IDs: TASK-<n> (Taiga) or VM-<n> (local: CI-unrelated bugs, side tasks).
# Journal: $AGENT_FACTORY_DIR/journal/index.md (one row per task) and
# journal/<id>.md (append-only events). Reports are archived under reports/<id>/
# and linked from the journal, never pasted into it.

factory_dir="${AGENT_FACTORY_DIR:-$HOME/.agent-factory}"
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

# ledger_row <main-checkout> <worktree> <id> <mode> <origin> <human-min> <outcome> <notes>:
# append one row to ledger.csv (columns from bootstrap/02-init-ledger.sh). Model,
# cost, sessions, agent minutes and agent-check.sh rounds come from the OpenCode
# sessions that ran in the worktree; agent minutes count prompt-to-idle time only.
# Jenkins rounds and build minutes stay empty until those scripts exist.
ledger_row() {
    local main="$1" wt="$2" ledger="$factory_dir/ledger.csv" disk="" sessions
    [[ -s "$ledger" ]] || { echo "No ledger at $ledger; run bootstrap/02-init-ledger.sh." >&2; return 1; }
    [[ -d "$wt" ]] && disk="$(du -sk "$wt" | awk '{printf "%.2f", $1 / 1048576}')"
    sessions="$(mktemp -d)"
    (cd "$main" && opencode session list --standalone --format json -n 1000) > "$sessions/list.json"
    python3 -I -c '
import json, sys
for s in json.load(open(sys.argv[1])):
    if s.get("directory") == sys.argv[2]: print(s["id"])' "$sessions/list.json" "$wt" |
    while read -r sid; do
        (cd "$main" && opencode session export --standalone "$sid") > "$sessions/$sid.json"
    done
    rm -f "$sessions/list.json"
    python3 -I - "$ledger" "$sessions" "$3" "$4" "$5" "$6" "$7" "$8" "$disk" <<'EOF'
import csv, datetime, glob, json, sys
ledger, sdir, task, mode, origin, human, outcome, notes, disk = sys.argv[1:]
models, providers, ids, cost, busy_ms, checks = [], [], [], 0.0, 0, 0
for path in sorted(glob.glob(sdir + "/*.json")):
    d = json.load(open(path))
    info = d["info"]
    ids.append(info["id"])
    cost += info.get("cost") or 0
    m = info.get("model") or {}
    if m.get("id") and m["id"] not in models: models.append(m["id"])
    if m.get("providerID") and m["providerID"] not in providers: providers.append(m["providerID"])
    start = None
    for msg in d["messages"]:
        if msg["type"] == "user" and start is None: start = msg["time"]["created"]
        elif msg["type"] == "idle" and start is not None:
            busy_ms += msg["time"]["created"] - start; start = None
        for part in msg.get("content") or []:
            st = part.get("state") or {}
            # A round is a check that ran; 126/127 mean it never started.
            if part.get("type") == "tool" and part.get("name") == "shell" and \
               "agent-check.sh" in ((st.get("input") or {}).get("command") or "") and \
               (st.get("metadata") or {}).get("exit") not in (126, 127):
                checks += 1
row = [task, datetime.date.today().isoformat(), mode, origin, "+".join(models), "+".join(providers),
       " ".join(ids), f"{cost:.4f}", f"{busy_ms / 60000:.1f}", human, checks, "", "", disk, outcome, notes]
with open(ledger, "a", newline="") as f: csv.writer(f).writerow(row)
print(f"Ledger: {len(ids)} session(s), ${cost:.4f}, {busy_ms / 60000:.1f} agent min, {checks} check round(s).")
EOF
    rm -rf "$sessions"
}

# project_id <main-checkout>: OpenCode's project ID for the repo.
project_id() {
    local main
    main="$(cd "$1" && pwd -P)"
    (cd "$main" && opencode api --standalone project.list) | python3 -I -c '
import json, sys
print(next(p["id"] for p in json.load(sys.stdin) if p.get("canonical") == sys.argv[1]))' "$main"
}
