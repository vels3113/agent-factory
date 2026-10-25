#!/usr/bin/env bash
# Local check for agents: incremental build of the current task worktree, then
# the named tests, with short output (first errors, failing tests). The full log
# stays in .agent/check/. Agents run it as an OpenCode background command:
# OpenCode 2.1.3 stops foreground shell commands after 2 minutes.
# Usage:
#   agent-check.sh [--preset <name>] [<test>...]   build, then run the named tests
#   agent-check.sh --prebuild [--preset <name>]    configure and build only (agent-task.sh start)
# Exit codes: 0 passed, 1 build failed, 2 tests failed, 3 setup error (not the
# change's fault), 4 timed out or no free build slot, 5 files changed during the check.
# Settings: CHECK_* lines and check_* functions in <project>/agent.env
# (setup-guide.md step 8). Each run is logged in the task journal, with its
# duration, and in journal/<id>.checks.tsv for the ledger.
set -euo pipefail
self="$(readlink -f "$0")"
source "$(dirname "$self")/agent-lib.sh"

usage() { sed -n '6,10p' "$self" | sed 's/^# \{0,1\}//' >&2; exit 3; }
setup_error() { echo "agent-check: SETUP ERROR: $1" >&2; exit 3; }
fmt_secs() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }
minutes() {
    [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] || setup_error "$1=$2 in agent.env is not a number of minutes."
    awk -v m="$2" 'BEGIN { printf "%d", m * 60 }'
}

mode=check preset=""
tests=()
while (($#)); do
    case "$1" in
        --prebuild) mode=prebuild ;;
        --preset) preset="${2:-}"; [[ -n "$preset" ]] || usage; shift ;;
        -*) usage ;;
        *) tests+=("$1") ;;
    esac
    shift
done
[[ "$mode" == prebuild && ${#tests[@]} -gt 0 ]] && usage

[[ -r "$factory_dir/vm.env" ]] || setup_error "missing $factory_dir/vm.env; run bootstrap/04-vm-facts.sh."
source "$factory_dir/vm.env"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || setup_error "not in a Git checkout; run it inside your task worktree."
id="$(basename "$top")"
{ valid_id "$id" && [[ "$(cd "$top/.." && pwd -P)" == "$(cd "$WORKTREES_DIR" 2>/dev/null && pwd -P)" ]]; } \
    || setup_error "$top is not a task worktree ($WORKTREES_DIR/<task-id>)."

# Defaults; <project>/agent.env overrides any of them. The check_* functions run
# in the worktree with PRESET, JOBS, LOAD and BUILD_DIR set (CMake: the preset's
# binaryDir once known, empty before the first configure; Make: .);
# check_test gets the test names as arguments.
CHECK_SLOTS=5               # checks running at once on the VM, all worktrees
CHECK_JOBS=""               # build jobs per check; default min(CPUs/2, RAM GB/2)
CHECK_LOAD=""               # no new jobs above this load; default CPU count
CHECK_PRESET=""             # CMake preset when --preset is not given; CMake needs one
CHECK_TIMEOUT_MIN=20        # one check, after it got its build slot
CHECK_PREBUILD_TIMEOUT_MIN=120
CHECK_WAIT_MIN=60           # waiting for a build slot or another check of the same build
case "$BUILD_SYSTEM" in
    cmake)
        # Builds go to the preset's binaryDir; BUILD_DIR is empty until CMake
        # has reported it (see configure below).
        check_configure() {
            [[ -n "$PRESET" ]] || { echo "No CMake preset: pass --preset <name>, or set CHECK_PRESET in agent.env."; return 3; }
            [[ -n "$BUILD_DIR" && -e "$BUILD_DIR/CMakeCache.txt" ]] && return 0
            local launcher=()
            command -v ccache >/dev/null && launcher=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
            cmake --preset "$PRESET" "${launcher[@]}"
        }
        check_build() { cmake --build "$BUILD_DIR" --parallel "$JOBS" -- -l "$LOAD"; }
        check_test() {
            local names
            names="$(IFS='|'; echo "$*")"
            ctest --test-dir "$BUILD_DIR" --output-on-failure --no-tests=error -j "$JOBS" -R "^($names)\$"
        }
        ;;
    make)
        with_ccache() { [[ -d /usr/lib/ccache ]] && command -v ccache >/dev/null && PATH="/usr/lib/ccache:$PATH"; return 0; }
        check_configure() { :; }
        check_build() { with_ccache; make -j"$JOBS" -l "$LOAD"; }
        check_test() { with_ccache; make -j"$JOBS" -l "$LOAD" "$@"; }
        ;;
esac
[[ -r "$PROJECT_DIR/agent.env" ]] || setup_error "missing $PROJECT_DIR/agent.env; run bootstrap/08-task-workflow.sh."
source "$PROJECT_DIR/agent.env"
declare -F check_build >/dev/null \
    || setup_error "build system '$BUILD_SYSTEM': define check_build and check_test in $PROJECT_DIR/agent.env (setup-guide.md step 8)."
declare -F check_configure >/dev/null || check_configure() { :; }
declare -F check_test >/dev/null || check_test() { echo "No check_test in agent.env; cannot run tests: $*"; return 3; }

export PRESET="${preset:-$CHECK_PRESET}" BUILD_DIR=""
[[ "$BUILD_SYSTEM" == make ]] && BUILD_DIR=.
checks="$top/.agent/check"
mkdir -p "$checks"
# CMake presets build in their own binaryDir. CMake reports it when it
# configures; it is remembered per preset until the preset files change.
dir_file=""
if [[ "$BUILD_SYSTEM" == cmake && -n "$PRESET" ]]; then
    dir_file="$checks/$PRESET.dir"
    if [[ -s "$dir_file" && ! "$top/CMakePresets.json" -nt "$dir_file" && ! "$top/CMakeUserPresets.json" -nt "$dir_file" ]]; then
        BUILD_DIR="$(cat "$dir_file")"
    fi
fi
cpus="${CPU_COUNT:-$(nproc)}"
jobs=$((cpus / 2)); mem_jobs=$((${MEM_TOTAL_GB:-0} / 2))
((mem_jobs > 0 && mem_jobs < jobs)) && jobs=$mem_jobs
export JOBS="${CHECK_JOBS:-$((jobs > 0 ? jobs : 1))}" LOAD="${CHECK_LOAD:-$cpus}"
run_s="$(minutes CHECK_TIMEOUT_MIN "$CHECK_TIMEOUT_MIN")"
[[ "$mode" == prebuild ]] && run_s="$(minutes CHECK_PREBUILD_TIMEOUT_MIN "$CHECK_PREBUILD_TIMEOUT_MIN")"
wait_s="$(minutes CHECK_WAIT_MIN "$CHECK_WAIT_MIN")"
[[ "$CHECK_SLOTS" =~ ^[1-9][0-9]*$ ]] || setup_error "CHECK_SLOTS=$CHECK_SLOTS in agent.env is not a positive number."

{ ls -1t "$checks"/*.log 2>/dev/null || true; } | tail -n +20 | xargs -r rm -f
log="$checks/$(date '+%Y%m%d-%H%M%S')-$mode-$$.log"
t0="$(date +%s)"
init_journal
label="$mode${PRESET:+ $PRESET}"

# finish <exit> <result> [excerpt-kind]: print the result, record the run, exit.
finish() {
    trap - TERM INT
    local secs=$(($(date +%s) - t0))
    echo "agent-check: $2 (${PRESET:+preset $PRESET, }$(fmt_secs "$secs"))"
    [[ -n "${3:-}" ]] && excerpt "$3"
    [[ -s "$log" ]] && echo "Full log: $log"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$t0" "$(date +%s)" "$mode" "$PRESET" "$1" "${OPENCODE_SESSION_ID:-}" \
        >> "$journal_dir/$id.checks.tsv"
    log_event "$id" "$label: $2, $(fmt_secs "$secs")"
    exit "$1"
}
trap 'finish 4 "STOPPED by a signal"' TERM INT

# excerpt build|test|tail: the part of the log worth reading, at most 50 lines.
excerpt() {
    python3 -I - "$1" "$log" <<'EOF'
import re, sys
kind, path = sys.argv[1:]
lines = open(path, errors="replace").read().splitlines()
out = []
if kind == "build":
    diag = re.compile(r"\b(fatal )?error:|^\S+\.l:\d+:|undefined reference|ld returned|^CMake Error")
    ctx = re.compile(r"^\s|note:|required from|In instantiation")
    shown, i = [], 0
    while i < len(lines) and len(shown) < 5:
        if diag.search(lines[i]) and lines[i] not in shown:
            shown.append(lines[i]); out.append(lines[i])
            j = i + 1
            while j < len(lines) and j <= i + 3 and ctx.search(lines[j]) and not diag.search(lines[j]):
                out.append(lines[j]); j += 1
            i = j
        else:
            i += 1
    more = len({l for l in lines if diag.search(l)} - set(shown))
    if more: out.append(f"... and {more} more error line(s)")
elif kind == "test" and "The following tests FAILED:" in lines:
    k = lines.index("The following tests FAILED:")
    names = [m.group(1) for l in lines[k + 1:] if (m := re.match(r"^\s*\d+ - (.+?) \([^)]*\)\s*$", l))]
    out.append(f"Failed tests ({len(names)}): " + ", ".join(names[:10]) + (f" and {len(names) - 10} more" if len(names) > 10 else ""))
    stop = re.compile(r"^\s*(Start\s+\d+:|\d+/\d+ Test\s+#)|^\d+% tests passed")
    for name in names[:3]:
        head = re.compile(r"Test\s+#\d+: " + re.escape(name) + r" \.*\*\*\*")
        start = next((n for n, l in enumerate(lines) if head.search(l)), None)
        if start is None: continue
        end = next((n for n in range(start + 1, len(lines)) if stop.search(lines[n])), len(lines))
        out.append(f"--- {name}")
        out += lines[max(start + 1, end - 15):end]
if not out:
    out = lines[-30:]
for l in out[:50]:
    print(l if len(l) <= 300 else l[:300] + " ...")
if len(out) > 50: print("... (cut; see the full log)")
EOF
}

# run_stage <timeout-s> <function> [args]: one check_* function, output to the log.
run_stage() {
    local secs="$1"
    shift
    printf '\n=== %s\n' "$*" >> "$log"
    timeout -k 10 "$secs" bash -c "$(declare -f); cd \"\$1\" && shift && \"\$@\"" _ "$top" "$@" >> "$log" 2>&1
}

# State of the worktree including untracked files, to detect edits during the check.
tree_state() {
    local idx rc=0
    idx="$(mktemp)"
    cp "$(git -C "$top" rev-parse --path-format=absolute --git-path index)" "$idx" 2>/dev/null || true
    { GIT_INDEX_FILE="$idx" git -C "$top" add -A && GIT_INDEX_FILE="$idx" git -C "$top" write-tree; } 2>/dev/null || rc=1
    rm -f "$idx"
    return $rc
}

lint_files() {
    local f rc=0
    for f in "$@"; do
        [[ -e "$f" ]] || continue
        case "$f" in
            *.py) python3 -I -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$f" || rc=1 ;;
            *.sh) bash -n "$f" || rc=1 ;;
        esac
    done
    return $rc
}

# Scope: nothing changed, or only Python and shell files (no build needed).
lint_only=()
if [[ "$mode" == check && ${#tests[@]} -eq 0 ]]; then
    base="$(git -C "$top" merge-base "origin/$BASE_BRANCH" HEAD 2>/dev/null)" \
        || setup_error "no common commit with origin/$BASE_BRANCH."
    mapfile -t changed < <({ git -C "$top" diff --name-only "$base"; git -C "$top" ls-files --others --exclude-standard; } | sort -u)
    [[ ${#changed[@]} -eq 0 ]] && finish 0 "OK, nothing to check (no changes against origin/$BASE_BRANCH)"
    if ! printf '%s\n' "${changed[@]}" | grep -qvE '\.(py|sh)$'; then lint_only=("${changed[@]}"); fi
fi

# Lower priority than interactive work; inherited by every build process.
renice -n 10 -p $$ >/dev/null 2>&1 || true
ionice -c2 -n7 -p $$ >/dev/null 2>&1 || true

# Wait for the build directory, then for a VM-wide build slot.
exec 9>"$checks/${PRESET:-default}.lock"
flock -w "$wait_s" 9 || finish 4 "TIMED OUT waiting $CHECK_WAIT_MIN min for another check or prebuild of this build"
slots="$factory_dir/check-slots"
mkdir -p "$slots"
until (($(date +%s) - t0 > wait_s)); do
    for ((i = 1; i <= CHECK_SLOTS; i++)); do
        exec 8>"$slots/$i"
        flock -n 8 && break 2
        exec 8>&-
    done
    sleep 2
done
{ : >&8; } 2>/dev/null || finish 4 "TIMED OUT waiting $CHECK_WAIT_MIN min for a free build slot ($CHECK_SLOTS in use)"

deadline=$(($(date +%s) + run_s))
left() { local s=$((deadline - $(date +%s))); echo $((s > 0 ? s : 1)); }
# stage_failed <rc> <result> <excerpt-kind>
stage_failed() {
    (($1 == 124 || $1 == 137)) && finish 4 "TIMED OUT after $CHECK_TIMEOUT_MIN min" tail
    [[ -n "${before:-}" && "$(tree_state)" != "$before" ]] && finish 5 "FILES CHANGED during the check; run it again"
    (($1 == 3)) && finish 3 "SETUP ERROR" tail
    finish "${4:-1}" "$2" "$3"
}

# configure: run check_configure; with a CMake preset, take the build directory
# CMake reports, refuse one outside the worktree (tasks would share a build),
# and keep it out of Git (info/exclude is shared by all worktrees).
configure() {
    run_stage "$(left)" check_configure || stage_failed $? "BUILD FAILED (configure)" build
    [[ -n "$dir_file" ]] || return 0
    if [[ -z "$BUILD_DIR" ]]; then
        BUILD_DIR="$(sed -n 's/^-- Build files have been written to: //p' "$log" | tail -n 1)"
        BUILD_DIR="$(cd "$BUILD_DIR" 2>/dev/null && pwd -P)" \
            || finish 3 "SETUP ERROR: CMake did not report the build directory of preset $PRESET" tail
        case "$BUILD_DIR/" in
            "$(cd "$top" && pwd -P)"/*) ;;
            *) finish 3 "SETUP ERROR: preset $PRESET builds outside the worktree ($BUILD_DIR), so tasks would share one build; set its binaryDir under \${sourceDir}" ;;
        esac
        echo "$BUILD_DIR" > "$dir_file"
        export BUILD_DIR
    fi
    local rel exclude
    rel="${BUILD_DIR#"$(cd "$top" && pwd -P)"/}"
    git -C "$top" check-ignore -q "$rel/CMakeCache.txt" && return 0
    exclude="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
    echo "/$rel/" >> "$exclude"
    log_event "$id" "added /$rel/ to $exclude (build directory of preset $PRESET)"
}

if [[ "$mode" == prebuild ]]; then
    configure
    run_stage "$(left)" check_build || stage_failed $? "BUILD FAILED" build
    finish 0 "OK, prebuilt"
fi

if [[ ${#lint_only[@]} -gt 0 ]]; then
    before="$(tree_state)" || setup_error "cannot read the worktree state."
    run_stage "$(left)" lint_files "${lint_only[@]}" || stage_failed $? "SYNTAX CHECK FAILED (Python/shell files only changed)" tail
    what="syntax check of ${#lint_only[@]} Python/shell file(s), no build needed"
else
    configure
    # After configure: a new preset build directory is only excluded from Git then.
    before="$(tree_state)" || setup_error "cannot read the worktree state."
    run_stage "$(left)" check_build || stage_failed $? "BUILD FAILED" build
    what="build"
    if [[ ${#tests[@]} -gt 0 ]]; then
        rc=0
        run_stage "$(left)" check_test "${tests[@]}" || rc=$?
        if ((rc != 0)) && grep -q 'No tests were found' "$log"; then finish 3 "SETUP ERROR: no test matches: ${tests[*]}" tail; fi
        ((rc == 0)) || stage_failed "$rc" "TESTS FAILED" test 2
        what="build, tests: ${tests[*]}"
    fi
fi
[[ "$(tree_state)" == "$before" ]] || finish 5 "FILES CHANGED during the check; run it again"
finish 0 "OK, $what"
