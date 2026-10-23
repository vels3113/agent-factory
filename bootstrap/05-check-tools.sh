#!/usr/bin/env bash
# Check the agent tooling on the VM after OpenCode is installed.
# Checks bear only for Make builds; CMake generates compile_commands.json itself.
# Usage: 05-check-tools.sh <path-to-project-repo>
set -uo pipefail

repo="${1:?Usage: $0 <path-to-project-repo>}"
cd "$repo" || { echo "Error: cannot cd to $repo" >&2; exit 1; }

missing=0
version() {
    printf '%-9s ' "$1"
    if command -v "$1" >/dev/null; then "$@" 2>&1 | head -n 1
    else echo "not installed"; missing=$((missing + 1)); fi
}

if [[ -e CMakeLists.txt ]]; then
    build_system=cmake
elif [[ -e Makefile || -e GNUmakefile ]]; then
    build_system=make
else
    build_system=unknown
fi
echo "Build system: $build_system"

version opencode --version
version git --version
version clangd --version
case "$build_system" in
    cmake) version cmake --version ;;
    make) version make --version; version bear --version ;;
    unknown) echo "bear      skipped (build system unknown; see 03-vm-facts.sh report)" ;;
esac

echo
if (( missing > 0 )); then
    echo "$missing tool(s) missing."
    exit 1
fi
echo "All tools present."
