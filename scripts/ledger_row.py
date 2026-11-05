"""Append one task's row to ledger.csv (called by ledger_row in agent-lib.sh,
which documents the columns' sources).
Usage: ledger_row.py <ledger.csv> <sessions-dir> <checks.tsv> <journal.md> <costs.tsv>
                     <task> <mode> <origin> <human-min> <outcome> <notes>
  sessions-dir  one OpenCode session export (JSON) per session of the task
  checks.tsv    journal/<task>.checks.tsv: agent-check.sh runs and wrapped commands
  journal.md    journal/<task>.md: each "pushed agent/<task> at <sha>" line from
                agent-task.sh push is one Jenkins round; no such line: empty (unknown)
  costs.tsv     the plugin's rows: what the provider charged per model response,
                with the key name and mode it ran under (columns 10 and 11)
  mode          the default; a task whose sessions the plugin recorded in
                background mode gets "background"
"""
import csv
import datetime
import glob
import json
import os
import sys

ledger, sdir, tsv, journal_md, costs_tsv, task, mode, origin, human, outcome, notes = sys.argv[1:]
charged = {}  # session -> cost the provider reported, from the plugin
keys, modes = {}, {}  # session -> key names and modes it ran under (newer rows only)
if os.path.exists(costs_tsv):
    for line in open(costs_tsv):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 7:
            charged[f[1]] = charged.get(f[1], 0.0) + float(f[6])
        if len(f) >= 11:
            if f[9]: keys.setdefault(f[1], set()).add(f[9])
            if f[10]: modes.setdefault(f[1], set()).add(f[10])
checks, failures = 0, 0  # agent-check.sh checks and wrapped commands OpenCode ran
if os.path.exists(tsv):
    for line in open(tsv):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 6 and f[2] in ("check", "command") and f[5]:
            checks += 1
            # A command with no numeric exit (killed, timed out) didn't succeed.
            code = int(f[4]) if f[4].lstrip("-").isdigit() else None
            failed = code in (1, 2, 5) if f[2] == "check" else code != 0
            failures += failed
models, providers, ids, cost, busy, tools, estimated = [], [], [], 0.0, [], [], 0
for path in sorted(glob.glob(sdir + "/*.json")):
    d = json.load(open(path))
    info = d["info"]
    ids.append(info["id"])
    if info["id"] in charged:
        cost += charged[info["id"]]
    elif info.get("cost"):
        cost += info["cost"]
        estimated += 1
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
jenkins = ""  # one round per push; empty when no push was logged
if os.path.exists(journal_md):
    pushes = sum(1 for line in open(journal_md) if f" pushed agent/{task} at " in line)
    jenkins = pushes or ""
used_keys = sorted(set().union(*(keys.get(i, set()) for i in ids)))
if "background" in set().union(*(modes.get(i, set()) for i in ids)):
    mode = "background"
if used_keys and used_keys != ["connect"]:
    notes = (notes + "; " if notes else "") + "key: " + "+".join(used_keys)
if estimated:
    notes = (notes + "; " if notes else "") + f"cost: OpenCode estimate for {estimated} of {len(ids)} session(s)"
row = [task, datetime.date.today().isoformat(), mode, origin, "+".join(models), "+".join(providers),
       " ".join(ids), f"{cost:.4f}", f"{busy_ms / 60000:.1f}", human, checks, failures, jenkins, outcome, notes]
with open(ledger, "a", newline="") as f: csv.writer(f).writerow(row)
print(f"Ledger: {len(ids)} session(s), ${cost:.4f}{' (partly estimated)' if estimated else ''}, {busy_ms / 60000:.1f} agent min, "
      f"{checks} check round(s), {failures} failed.")
