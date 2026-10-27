"""Append one task's row to ledger.csv (called by ledger_row in agent-lib.sh,
which documents the columns' sources).
Usage: ledger_row.py <ledger.csv> <sessions-dir> <checks.tsv> <costs.tsv>
                     <task> <mode> <origin> <human-min> <outcome> <notes>
  sessions-dir  one OpenCode session export (JSON) per session of the task
  checks.tsv    journal/<task>.checks.tsv: agent-check.sh runs and wrapped commands
  costs.tsv     the plugin's rows: what the provider charged per model response
"""
import csv
import datetime
import glob
import json
import os
import sys

ledger, sdir, tsv, costs_tsv, task, mode, origin, human, outcome, notes = sys.argv[1:]
charged = {}  # session -> cost the provider reported, from the plugin
if os.path.exists(costs_tsv):
    for line in open(costs_tsv):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 7:
            charged[f[1]] = charged.get(f[1], 0.0) + float(f[6])
checks, failures = 0, 0  # agent-check.sh checks and wrapped commands OpenCode ran
if os.path.exists(tsv):
    for line in open(tsv):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 6 and f[2] in ("check", "command") and f[5]:
            checks += 1
            failed = int(f[4]) in (1, 2, 5) if f[2] == "check" else int(f[4]) != 0
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
if estimated:
    notes = (notes + "; " if notes else "") + f"cost: OpenCode estimate for {estimated} of {len(ids)} session(s)"
row = [task, datetime.date.today().isoformat(), mode, origin, "+".join(models), "+".join(providers),
       " ".join(ids), f"{cost:.4f}", f"{busy_ms / 60000:.1f}", human, checks, failures, "", outcome, notes]
with open(ledger, "a", newline="") as f: csv.writer(f).writerow(row)
print(f"Ledger: {len(ids)} session(s), ${cost:.4f}{' (partly estimated)' if estimated else ''}, {busy_ms / 60000:.1f} agent min, "
      f"{checks} check round(s), {failures} failed.")
