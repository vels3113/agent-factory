#!/usr/bin/env bash
# Check the agent tooling on the VM after OpenCode is installed.
# Checks bear only for Make builds; CMake generates compile_commands.json itself.
# Reads the repo path and build system from vm.env (written by 04-vm-facts.sh).
# Usage: 06-check-tools.sh [project-dir]   (overrides vm.env; the repo is <project-dir>/main)
set -uo pipefail

vm_env="${AGENT_FACTORY_DIR:-$HOME/.agent-factory}/vm.env"
if [[ -f "$vm_env" ]]; then
    # shellcheck source=/dev/null
    source "$vm_env"
else
    echo "Note: $vm_env not found; run 04-vm-facts.sh first. Detecting the build system here."
fi

if [[ -n "${1:-}" ]]; then repo="$1/main"; else repo="${PROJECT_REPO:-}"; fi
[[ -n "$repo" ]] || { echo "Usage: $0 [project-dir] (required without vm.env)" >&2; exit 1; }
cd "$repo" || { echo "Error: cannot cd to $repo" >&2; exit 1; }

missing=0
version() {
    printf '%-9s ' "$1"
    if command -v "$1" >/dev/null; then "$@" 2>&1 | head -n 1
    else echo "not installed"; missing=$((missing + 1)); fi
}

if [[ -n "${BUILD_SYSTEM:-}" && "$(pwd)" == "${PROJECT_REPO:-}" ]]; then
    build_system="$BUILD_SYSTEM"
elif [[ -e CMakeLists.txt ]]; then
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
    unknown) echo "bear      skipped (build system unknown; see BUILD_SYSTEM in vm.env)" ;;
esac

echo
if (( missing > 0 )); then
    echo "$missing tool(s) missing."
    exit 1
fi
echo "All tools present."
