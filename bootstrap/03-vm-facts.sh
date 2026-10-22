#!/usr/bin/env bash
# Collect VM and repository facts that answer the plan's open questions.
# Usage: 03-vm-facts.sh <path-to-project-repo> [output-file]
set -uo pipefail

repo="${1:?Usage: $0 <path-to-project-repo> [output-file]}"
out="${2:-${AGENT_WORK_DIR:-$HOME/agent-work}/vm-facts.txt}"
cd "$repo" || { echo "Error: cannot cd to $repo" >&2; exit 1; }
mkdir -p "$(dirname "$out")"

section() { printf '\n## %s\n' "$1"; }
run() { printf '$ %s\n' "$*"; "$@" 2>&1 || printf '(exit %s)\n' "$?"; }
version() { printf '%-8s ' "$1"; if command -v "$1" >/dev/null; then "$@" 2>&1 | head -n 1; else echo "not installed"; fi; }

{
    printf '# VM facts — %s — %s\n' "$(hostname)" "$(date -Iseconds)"
    printf 'Repository: %s\n' "$(pwd)"

    section "Build system (CMake or Make?)"
    for f in CMakeLists.txt Makefile GNUmakefile configure meson.build; do
        [[ -e "$f" ]] && echo "found: $f"
    done
    echo "flex sources: $(git ls-files '*.l' | wc -l)"

    section "Git server"
    run git remote -v

    section "Prerequisites"
    version node --version
    version npm --version
    version git --version
    version clangd --version
    version bear --version
    version ccache --version

    section "CPU and RAM"
    run nproc
    run free -h

    section "Disk"
    run df -h . "$HOME"
    run du -sh .
} | tee "$out"

echo
echo "Saved to $out"
echo "Also note: does VS Code run on the VM directly, or locally with Remote-SSH?"
