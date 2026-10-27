#!/usr/bin/env bash
# Stub cmake: --preset <name> configures into <worktree>/build/<name>, preset
# "outside" into a folder next to the worktree; every call is logged to $STUB_CMAKE_LOG.
echo "cmake $*" >> "$STUB_CMAKE_LOG"
case "$1" in
    --preset)
        d="$PWD/build/$2"
        [[ "$2" == outside ]] && d="$(dirname "$PWD")/shared-build"
        mkdir -p "$d" && touch "$d/CMakeCache.txt"
        echo "-- Build files have been written to: $d" ;;
    --list-presets=configure)
        printf 'Available configure presets:\n\n  "dev" - Dev\n  "rel" - Release\n' ;;
esac
