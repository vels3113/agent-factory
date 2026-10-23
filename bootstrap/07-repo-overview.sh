#!/usr/bin/env bash
# Summarize the project repo's layout for drafting the AGENTS.md codebase map.
# Read-only; output is bounded so it can be pasted into a chat.
# Usage: 07-repo-overview.sh <project-dir> [output-file]   (the repo is <project-dir>/main)
set -uo pipefail

project_dir="${1:?Usage: $0 <project-dir> [output-file]   (e.g. ~/<project>)}"
out="${2:-${AGENT_FACTORY_DIR:-$HOME/.agent-factory}/repo-overview.txt}"
cd "$project_dir/main" || { echo "Error: cannot cd to $project_dir/main" >&2; exit 1; }
mkdir -p "$(dirname "$out")"

section() { printf '\n## %s\n' "$1"; }

{
    printf '# Repo overview — %s — %s\n' "$(basename "$(cd "$project_dir" && pwd)")" "$(date -Iseconds)"
    printf 'Tracked files: %s\n' "$(git ls-files | wc -l)"

    section "Files by extension (top 15)"
    git ls-files | sed -n 's/.*\.\([^./]*\)$/\1/p' | sort | uniq -c | sort -rn | head -n 15

    section "Directories, two levels (alphabetical; tracked files below each)"
    git ls-files | awk -F/ 'NF>1 {print $1} NF>2 {print $1"/"$2}' | sort | uniq -c \
        | awk '{printf "%-42s %6d\n", ($2 ~ /\// ? "  " : "") $2, $1}' | head -n 200

    section "Build entry points (depth <= 3)"
    git ls-files | grep -E '(^|/)(CMakeLists\.txt|[A-Za-z]*[Mm]akefile|.*\.mk|.*\.cmake|configure(\.ac)?|Jenkinsfile)$' \
        | awk -F/ 'NF<=4' | head -n 30

    section "flex sources"
    git ls-files '*.l' | head -n 30

    section "Likely test directories"
    git ls-files | awk -F/ '{for (i=1; i<NF; i++) if ($i ~ /^(tests?|unittests?|testing|qa|gtest?)$/) {p=$1; for (j=2; j<=i; j++) p=p"/"$j; print p; break}}' \
        | sort -u | head -n 20

    section "Ignored build output (.gitignore, top level)"
    [[ -f .gitignore ]] && grep -vE '^\s*(#|$)' .gitignore | head -n 30

    section "Docs: README-type files at the top two levels"
    git ls-files | grep -iE '^([^/]+/)?(README|CONTRIBUTING|BUILD|INSTALL)[^/]*$' | head -n 20

    section "Docs: paths matching *docs* (tracked files per directory)"
    git ls-files | grep -i 'docs' | sed -e 's|/[^/]*$||' -e 't' -e 's|.*|(top level)|' | sort | uniq -c | head -n 30
} | tee "$out"

echo
echo "Saved to $out"
