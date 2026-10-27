"""Values from OpenCode's JSON output, read on stdin.
Usage:
  opencode session list --format json | opencode_json.py sessions-in <dir>
      the IDs of the sessions that ran in <dir>, one per line
  opencode api project.list | opencode_json.py project-id <canonical-dir>
      the ID of the project whose checkout is <canonical-dir>
  opencode api project.list | opencode_json.py start-command <project-id>
      the project's start command, or an empty line
"""
import json
import sys

what, arg = sys.argv[1:]
data = json.load(sys.stdin)
if what == "sessions-in":
    for s in data:
        if s.get("directory") == arg: print(s["id"])
elif what == "project-id":
    print(next(p["id"] for p in data if p.get("canonical") == arg))
elif what == "start-command":
    p = next(p for p in data if p["id"] == arg)
    print((p.get("commands") or {}).get("start", ""))
else:
    sys.exit(f"unknown query: {what}")
