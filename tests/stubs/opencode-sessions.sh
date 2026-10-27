#!/usr/bin/env bash
# Stands in for `opencode session list|export` with fake sessions:
# $FAKE_SESSIONS/list.json and $FAKE_SESSIONS/<session-id>.json.
case "$2" in
    list) cat "$FAKE_SESSIONS/list.json" ;;
    export) cat "$FAKE_SESSIONS/$4.json" ;;
esac
