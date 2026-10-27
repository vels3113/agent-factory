#!/usr/bin/env bash
# Set up the agent-check.sh profile for a project folder from
# 03-project-layout.sh: the project's CI procedure (presets, build, test runs)
# in the terms of scripts/agent-check.sh. Run after 08-task-workflow.sh.
#   1. 09-check-profile.sh <project-dir>
#      Writes the draft main/agent-check.draft.conf (kept out of Git): a copy
#      of the installed profile if there is one, otherwise a new CMake or Make
#      profile for BUILD_SYSTEM (vm.env), with the CMake presets the Jenkinsfile
#      builds. Never overwrites a draft. Prints the OpenCode prompt that
#      completes it. The profile's header describes its interface.
#   2. 09-check-profile.sh <project-dir> --validate [<preset>...]
#      Builds the presets (default: the default preset) and lists the test
#      suites in a throwaway task worktree, then installs the draft as
#      <project-dir>/agent-check.conf (asks before replacing a different one).
# Usage: 09-check-profile.sh <project-dir> [--validate [<preset>...]]
set -euo pipefail

usage="Usage: $0 <project-dir> [--validate [<preset>...]]"
project_dir="${1:?$usage}"
shift
validate=0
if [[ "${1:-}" == --validate ]]; then validate=1; shift; elif [[ $# -gt 0 ]]; then echo "$usage" >&2; exit 1; fi
project_dir="$(cd "$project_dir" 2>/dev/null && pwd)" || { echo "Error: cannot cd to $project_dir" >&2; exit 1; }
main="$project_dir/main"
here="$(dirname "$(readlink -f "$0")")"
scripts="$(cd "$here/../scripts" && pwd)"
templates="$(cd "$here/../templates/check-profile" && pwd)"
source "$scripts/agent-lib.sh"
[[ -r "$factory_dir/vm.env" ]] || { echo "Error: missing $factory_dir/vm.env; run 04-vm-facts.sh." >&2; exit 1; }
source "$factory_dir/vm.env"
[[ -r "$project_dir/agent.env" ]] || { echo "Error: missing $project_dir/agent.env; run 08-task-workflow.sh." >&2; exit 1; }
draft="$main/agent-check.draft.conf"
profile="$project_dir/agent-check.conf"

# The draft lives in main/ so OpenCode can edit it there (agents may not edit
# the installed profile); info/exclude keeps it out of Git.
exclude="$(git -C "$main" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
grep -qx '/agent-check.draft.conf' "$exclude" 2>/dev/null || echo '/agent-check.draft.conf' >> "$exclude"

prompt="Complete agent-check.draft.conf in this directory: the profile agent-check.sh uses to run this repo's CI procedure locally. Its header describes the interface; keep the header. Read the Jenkinsfile, the scripts it calls and CMakePresets.json if there is one. Set CHECK_PRESETS to the build configurations CI builds and CHECK_DEFAULT_PRESET to the one for everyday changes. Write one test_<suite> function per test run CI does, running only the named tests when names are given, plus list_<suite> when the test runner can list its tests, and set each suite's parser in CHECK_PARSER. Adjust CHECK_BUILD_PATHS to the files whose change needs a build. If the build files already use ccache (for example a compiler launcher in CMakeLists.txt or the presets, or ccache in the Makefiles), remove the profile's ccache lines (the launcher in check_configure, or with_ccache). Replace every TODO. Edit no other file. At the end, list what CI runs that the profile leaves out."

# new_profile cmake|make: a new profile, with the presets in $use (TODO if none):
# the interface header, then the build system's draft (templates/check-profile/).
new_profile() {
    cat "$templates/header.conf"
    if [[ "$1" == cmake ]]; then
        printf '# Found by 09-check-profile.sh: configure presets: %s; Jenkinsfiles: %s;\n' \
            "${presets[*]:-none found}" "${jenkinsfiles[*]:-none found}"
        printf '# presets the Jenkinsfiles build: %s.\n' "${ci[*]:-none found}"
        echo '# Configure presets CI builds; the default is the one for everyday changes,'
        echo '# also used by the prebuild.'
        printf 'CHECK_PRESETS=(%s)\nCHECK_DEFAULT_PRESET=%s\n' "${use[*]:-TODO}" "${use[0]:-TODO}"
    fi
    cat "$templates/$1.conf"
}

if ((!validate)); then
    if [[ -e "$draft" ]]; then
        echo "Kept existing draft $draft."
    elif [[ -e "$profile" ]]; then
        cp "$profile" "$draft"
        echo "Draft $draft: copy of the installed profile."
    else
        kind=cmake
        if [[ "$BUILD_SYSTEM" != cmake ]]; then
            kind=make
            [[ "$BUILD_SYSTEM" == make ]] || echo "WARNING: BUILD_SYSTEM=$BUILD_SYSTEM in vm.env; writing a Make profile." >&2
        fi
        presets=() ci=()
        if [[ "$kind" == cmake && -e "$main/CMakePresets.json" ]] && command -v cmake >/dev/null; then
            mapfile -t presets < <(cd "$main" && cmake --list-presets=configure 2>/dev/null | sed -n 's/^ *"\([^"]*\)".*/\1/p')
        fi
        mapfile -t jenkinsfiles < <(git -C "$main" ls-files 'Jenkinsfile*' '*/Jenkinsfile*' '*.jenkinsfile')
        if [[ ${#jenkinsfiles[@]} -gt 0 && ${#presets[@]} -gt 0 ]]; then
            mapfile -t ci < <(cd "$main" && grep -ohE -- '--preset[= ]+"?[A-Za-z0-9_.-]+' "${jenkinsfiles[@]}" \
                | sed -E 's/--preset[= ]+"?//' | awk '!seen[$0]++')
        fi
        if [[ ${#ci[@]} -gt 0 ]]; then use=("${ci[@]}"); else use=("${presets[@]}"); fi
        new_profile "$kind" > "$draft"
        echo "Draft $draft: new $kind profile."
    fi
    cat <<EOF

Next:
  1. Complete the draft with OpenCode (pick a model with /models first, as in step 7):
       cd $main && opencode
     and send this prompt:

$(fold -s -w 76 <<<"$prompt" | sed 's/^/       /')

  2. Review the draft, then validate and install it:
       $0 $project_dir --validate
EOF
    exit 0
fi

# --validate: the draft if there is one, otherwise the installed profile.
src="$draft"
[[ -e "$src" ]] || src="$profile"
[[ -e "$src" ]] || { echo "Error: no draft or profile; run $0 $project_dir first." >&2; exit 1; }
bash -n "$src" || { echo "Error: $src has a syntax error." >&2; exit 1; }
if grep -nE '^[^#]*TODO' "$src" >&2; then echo "Error: replace the TODO values in $src first." >&2; exit 1; fi
read -r -a presets <<<"$(bash -c 'source "$1"; echo "${CHECK_DEFAULT_PRESET:-${CHECK_PRESETS[0]}}"' _ "$src")"
[[ $# -gt 0 ]] && presets=("$@")

# A throwaway local task worktree: a fresh build in a realistic place.
id="$("$scripts/agent-task.sh" new "agent-check profile validation")"
pid="$(project_id "$main")"
(cd "$main" && opencode api --standalone worktree.create -d "{\"projectID\":\"$pid\",\"name\":\"$id\"}") >/dev/null \
    || { echo "Error: cannot create a worktree for $id." >&2; exit 1; }
wt="$WORKTREES_DIR/$id"
cleanup() {
    mkdir -p "$reports_dir/$id"
    cp "$wt"/.agent/check/*.log "$reports_dir/$id/" 2>/dev/null || true
    (cd "$main" && opencode api --standalone worktree.remove \
        -d "{\"projectID\":\"$pid\",\"directory\":\"$wt\",\"force\":true}") >/dev/null 2>&1 || true
    git -C "$main" branch -q -D "agent/$id" 2>/dev/null || true
    log_event "$id" "validation worktree removed; logs in ../reports/$id/"
    set_status "$id" done
}
trap cleanup EXIT

ok=1
for p in "${presets[@]}"; do
    echo "# preset $p: prebuild (a cold build can take long)"
    (cd "$wt" && AGENT_CHECK_PROFILE="$src" "$scripts/agent-check.sh" --prebuild --preset "$p") || { ok=0; break; }
    if [[ -n "$(git -C "$wt" status --porcelain)" ]]; then
        echo "Build output shows up as changes in Git:" >&2
        git -C "$wt" status --porcelain | head -n 5 >&2
        ok=0
        break
    fi
done
echo "# agent-check.sh --list"
(cd "$wt" && AGENT_CHECK_PROFILE="$src" "$scripts/agent-check.sh" --list) || ok=0
echo "# step times (task journal $journal_dir/$id.md)"
grep -E 'prebuild ' "$journal_dir/$id.md" || true
((ok)) || { echo "Validation failed; profile not installed. Logs: $reports_dir/$id/" >&2; exit 1; }

if [[ "$src" == "$draft" ]]; then
    if [[ -e "$profile" ]] && ! cmp -s "$draft" "$profile"; then
        read -r -p "Replace the installed $profile with the draft? [y/N] " answer
        [[ "$answer" == [yY] ]] || { echo "Profile not replaced; the draft stays in $draft."; exit 0; }
    fi
    mv "$draft" "$profile"
    echo "Installed $profile."
else
    echo "Installed profile $profile is valid."
fi
