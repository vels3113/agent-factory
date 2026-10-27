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
# script exists.
ledger_row() {
    local main="$1" wt="$2" ledger="$factory_dir/ledger.csv" sessions
    [[ -s "$ledger" ]] || { echo "No ledger at $ledger; run bootstrap/02-init-ledger.sh." >&2; return 1; }
    [[ "$(head -n 1 "$ledger")" == "$ledger_header" ]] \
        || { echo "$ledger has older columns; move it aside and run bootstrap/02-init-ledger.sh." >&2; return 1; }
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
    python3 -I - "$ledger" "$sessions" "$journal_dir/$3.checks.tsv" "$3" "$4" "$5" "$6" "$7" "$8" <<'EOF'
import csv, datetime, glob, json, os, sys
ledger, sdir, tsv, task, mode, origin, human, outcome, notes = sys.argv[1:]
checks, failures = 0, 0  # agent-check.sh checks and wrapped commands OpenCode ran
if os.path.exists(tsv):
    for line in open(tsv):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 6 and f[2] in ("check", "command") and f[5]:
            checks += 1
            failed = int(f[4]) in (1, 2, 5) if f[2] == "check" else int(f[4]) != 0
            failures += failed
models, providers, ids, cost, busy, tools = [], [], [], 0.0, [], []
for path in sorted(glob.glob(sdir + "/*.json")):
    d = json.load(open(path))
    info = d["info"]
    ids.append(info["id"])
    cost += info.get("cost") or 0
    m = info.get("model") or {}
    if m.get("id") and m["id"] not in models: models.append(m["id"])
    if m.get("providerID") and m["providerID"] not in providers: providers.append(m["providerID"])
    # A "synthetic" message resumes the agent when a background command ends.
    start = None
    for msg in d["messages"]:
        if msg["type"] in ("user", "synthetic") and start is None: start = msg["time"]["created"]
        elif msg["type"] == "idle" and start is not None:
            busy.append((start, msg["time"]["created"])); start = None
    for msg in d["messages"]:
        if msg["type"] != "assistant": continue
        for c in msg.get("content") or []:
            t = c.get("time") or {}
            if c.get("type") == "tool" and t.get("created") and t.get("completed"):
                tools.append((t["created"], t["completed"]))
merged = []  # tool spans, parallel calls joined
for s, e in sorted(tools):
    if merged and s <= merged[-1][1]: merged[-1][1] = max(merged[-1][1], e)
    else: merged.append([s, e])
busy_ms = sum(e - s for s, e in busy)
busy_ms -= sum(max(0, min(e, te) - max(s, ts)) for s, e in busy for ts, te in merged)
row = [task, datetime.date.today().isoformat(), mode, origin, "+".join(models), "+".join(providers),
       " ".join(ids), f"{cost:.4f}", f"{busy_ms / 60000:.1f}", human, checks, failures, "", outcome, notes]
with open(ledger, "a", newline="") as f: csv.writer(f).writerow(row)
print(f"Ledger: {len(ids)} session(s), ${cost:.4f}, {busy_ms / 60000:.1f} agent min, "
      f"{checks} check round(s), {failures} failed.")
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
