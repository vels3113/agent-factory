#!/usr/bin/env bash
# Set up the project layout: a parent folder named after the project holds the
# repo (main/), the task worktrees (worktrees/), and the OpenCode config and
# AGENTS.md that every checkout under it loads. Nothing is committed to the repo.
# Usage: 03-project-layout.sh [--vscode] <project-name> [repo-path-or-git-url]
#   The repo argument is needed only while <project>/main does not exist yet.
#   --vscode  also create <project>/.vscode/settings.json so VS Code, opened on
#             <project>, shows main/ and every worktree in Source Control.
set -euo pipefail

usage="Usage: $0 [--vscode] <project-name> [repo-path-or-git-url]"
vscode=false
args=()
for arg in "$@"; do
    case "$arg" in
        --vscode) vscode=true ;;
        -*) echo "$usage" >&2; exit 1 ;;
        *) args+=("$arg") ;;
    esac
done
name="${args[0]:?$usage}"
source_repo="${args[1]:-}"
templates="$(cd "$(dirname "$0")/../templates" && pwd)"
parent="${AGENT_PROJECTS_DIR:-$HOME}/$name"
main="$parent/main"

if [[ -z "$source_repo" ]] && ! git -C "$main" rev-parse --git-dir >/dev/null 2>&1; then
    echo "No repo at $main yet; pass a repo path or Git URL. $usage" >&2
    exit 1
fi
mkdir -p "$parent/worktrees" "$parent/instructions"

# Main checkout: reuse it, move an existing clone into place, or clone a URL.
if git -C "$main" rev-parse --git-dir >/dev/null 2>&1; then
    echo "Repo already at $main."
elif [[ -d "$source_repo" ]]; then
    src="$(git -C "$source_repo" rev-parse --show-toplevel)"
    read -r -p "Move $src to $main? Open editors and terminals in it will need the new path. [y/N] " answer
    [[ "$answer" == [yY] ]] || { echo "Not moved. Nothing else changed."; exit 0; }
    mv "$src" "$main"
    git -C "$main" worktree repair
else
    git clone "$source_repo" "$main"
fi

# AGENTS.md: take the /init result from the repo root if it is untracked,
# otherwise start from the template. Never overwrite an existing copy.
agents_md="$parent/instructions/AGENTS.md"
if [[ -e "$agents_md" ]]; then
    echo "Kept existing $agents_md."
elif [[ -f "$main/AGENTS.md" ]] && ! git -C "$main" ls-files --error-unmatch AGENTS.md >/dev/null 2>&1; then
    mv "$main/AGENTS.md" "$agents_md"
    echo "Moved $main/AGENTS.md to $agents_md."
else
    cp "$templates/AGENTS.md" "$agents_md"
    echo "Created $agents_md from the template; fill it with /init (setup-guide.md step 7)."
fi

# OpenCode project config above all checkouts; never overwrite.
config="$parent/opencode.jsonc"
if [[ -e "$config" ]]; then
    echo "Kept existing $config."
else
    content="$(<"$templates/opencode.jsonc")"
    printf '%s\n' "${content//TODO_INSTRUCTIONS_PATH/$agents_md}" > "$config"
    echo "Created $config."
fi

# VS Code opened on <project>: detect main/ (depth 1) and worktrees/<id> (depth 2).
if $vscode; then
    settings="$parent/.vscode/settings.json"
    if [[ ! -e "$settings" ]]; then
        mkdir -p "$parent/.vscode"
        cat > "$settings" <<'JSON'
{
  "git.autoRepositoryDetection": true,
  "git.repositoryScanMaxDepth": 2
}
JSON
        echo "Created $settings."
    elif grep -q '"git.repositoryScanMaxDepth"' "$settings"; then
        echo "Kept existing $settings."
    else
        echo "WARNING: $settings exists; add \"git.repositoryScanMaxDepth\": 2 to it by hand." >&2
    fi
fi

echo
echo "Layout:"
echo "  $parent/opencode.jsonc"
echo "  $parent/instructions/AGENTS.md"
echo "  $parent/main/            (repo)"
echo "  $parent/worktrees/       (task worktrees)"
$vscode && echo "  $parent/.vscode/settings.json  (open $parent in VS Code)"
echo "Next: bootstrap/04-vm-facts.sh $parent"
