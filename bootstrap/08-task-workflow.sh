#!/usr/bin/env bash
# Set up the agent task workflow (scripts/agent-task.sh) for a project folder
# from 03-project-layout.sh. Run after 05-install-opencode.sh.
#   - <project>/agent.env: BASE_BRANCH that task branches start from
#   - registers scripts/agent-worktree-setup.sh as OpenCode's project start
#     command, run in every worktree OpenCode creates
#   - main/.git/info/exclude: .agent/ (agent reports stay out of Git)
#   - ~/.local/bin: links to agent-task.sh, agent-check.sh, agent-worktree-setup.sh and model-suggest.sh
#   - the agent task journal under ~/.agent-factory/journal
# Usage: 08-task-workflow.sh <project-dir> <base-branch>
set -euo pipefail

usage="Usage: $0 <project-dir> <base-branch>   (e.g. ~/<project> lemon)"
project_dir="${1:?$usage}"
base="${2:?$usage}"
project_dir="$(cd "$project_dir" 2>/dev/null && pwd)" || { echo "Error: cannot cd to $1" >&2; exit 1; }
main="$project_dir/main"
scripts="$(cd "$(dirname "$0")/../scripts" && pwd)"
git -C "$main" rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "Error: no repo at $main; run 03-project-layout.sh first." >&2; exit 1; }
command -v opencode >/dev/null || { echo "Error: opencode not on PATH; run 05-install-opencode.sh." >&2; exit 1; }
git -C "$main" rev-parse --verify -q "origin/$base" >/dev/null \
    || { echo "Error: origin/$base not found; check the branch name or run git fetch." >&2; exit 1; }
source "$scripts/agent-lib.sh"

# Base branch: never overwrite.
env_file="$project_dir/agent.env"
if [[ -e "$env_file" ]]; then
    echo "Kept existing $env_file ($(grep '^BASE_BRANCH=' "$env_file" || echo 'no BASE_BRANCH'))."
else
    printf 'BASE_BRANCH=%q\n' "$base" > "$env_file"
    echo "Created $env_file."
fi

# Keep agent reports out of Git; info/exclude is shared by all worktrees.
exclude="$(git -C "$main" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
mkdir -p "$(dirname "$exclude")"
grep -qx '.agent/' "$exclude" 2>/dev/null || { echo '.agent/' >> "$exclude"; echo "Added .agent/ to $exclude."; }

# Commands on PATH for you and the agents (Ubuntu adds ~/.local/bin to PATH at login).
mkdir -p "$HOME/.local/bin"
for s in agent-task.sh agent-check.sh agent-worktree-setup.sh model-suggest.sh; do
    link="$HOME/.local/bin/$s"
    if [[ -L "$link" && "$(readlink -f "$link")" == "$scripts/$s" ]]; then
        :
    elif [[ -e "$link" || -L "$link" ]]; then
        echo "WARNING: $link exists and points elsewhere; left unchanged." >&2
    else
        ln -s "$scripts/$s" "$link"
        echo "Linked $link."
    fi
done

# OpenCode project start command: ask before replacing a different one.
start_cmd="$scripts/agent-worktree-setup.sh"
pid="$(project_id "$main")"
current="$(cd "$main" && opencode api --standalone project.list | python3 -I -c '
import json, sys
p = next(p for p in json.load(sys.stdin) if p["id"] == sys.argv[1])
print((p.get("commands") or {}).get("start", ""))' "$pid")"
if [[ "$current" == "$start_cmd" ]]; then
    echo "OpenCode start command already set."
else
    if [[ -n "$current" ]]; then
        read -r -p "Replace OpenCode start command '$current' with '$start_cmd'? [y/N] " answer
        [[ "$answer" == [yY] ]] || { echo "Start command not changed."; exit 0; }
    fi
    (cd "$main" && opencode api --standalone project.update --param "projectID=$pid" \
        -d "{\"commands\":{\"start\":\"$start_cmd\"}}") >/dev/null
    echo "Set OpenCode start command: $start_cmd"
fi

init_journal
echo "Journal: $index"
grep -q '"worktree"' "$project_dir/opencode.jsonc" 2>/dev/null \
    || echo "WARNING: add \"worktree\": { \"directory\": \"../worktrees\" } to $project_dir/opencode.jsonc (see templates/opencode.jsonc)." >&2
echo "Next: agent-task.sh start TASK-<n>"
