#!/usr/bin/env bash
# Stands in for OpenCode's interactive UI in the test sandbox (tests/lib.sh):
# `opencode <dir>` writes a report and exits after STUB_SESSION_SECONDS
# (default 0); every other command goes to the real binary, $OPENCODE_REAL.
if [[ $# -eq 1 && -d "$1" ]]; then
    mkdir -p "$1/.agent" && echo "# stub session report" > "$1/.agent/report.md"
    sleep "${STUB_SESSION_SECONDS:-0}"
    exit 0
fi
exec "$OPENCODE_REAL" "$@"
