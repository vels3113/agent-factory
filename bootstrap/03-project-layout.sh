#!/usr/bin/env bash
# Set up the project layout: a parent folder named after the project holds the
# repo (main/), the task worktrees (worktrees/), and the OpenCode config and
# AGENTS.md that every checkout under it loads. Nothing is committed to the repo.
# Usage: 03-project-layout.sh <project-name> <repo-path-or-git-url>
set -euo pipefail

name="${1:?Usage: $0 <project-name> <repo-path-or-git-url>}"
source_repo="${2:?Usage: $0 <project-name> <repo-path-or-git-url>}"
templates="$(cd "$(dirname "$0")/../templates" && pwd)"
parent="${AGENT_PROJECTS_DIR:-$HOME}/$name"
main="$parent/main"

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

echo
echo "Layout:"
echo "  $parent/opencode.jsonc"
echo "  $parent/instructions/AGENTS.md"
echo "  $parent/main/            (repo)"
echo "  $parent/worktrees/       (task worktrees)"
echo "Next: bootstrap/04-vm-facts.sh $parent"
