#!/usr/bin/env bash
# Local check for agents: runs the project's CI procedure as its check profile
# describes it (<project>/agent-check.conf, from bootstrap/09-check-profile.sh),
# for one or more presets, and adds what agents need: short output (first
# errors, failing tests), no build when the change doesn't need one, a
# prebuild, VM-wide build slots, low priority, time limits, and logs.
# Agents run it as an OpenCode background command: OpenCode 2.1.3 stops
# foreground shell commands after 2 minutes.
# Usage:
#   agent-check.sh [--preset <name>]... [--suite <name>] [<test>...]
#       build each preset (default: the profile's), then run the named tests
#       (default suite), or the whole suite when --suite is given without names
#   agent-check.sh --prebuild [--preset <name>]   configure and build only (agent-task.sh start)
#   agent-check.sh --list                        presets, test suites and their tests
# Exit codes: 0 passed, 1 build failed, 2 tests failed, 3 setup error (not the
# change's fault), 4 timed out or no free build slot, 5 files changed during the check.
# Each run is logged in the task journal with its step durations, and in
# journal/<id>.checks.tsv for the ledger: start, end, kind, presets, exit code,
# OpenCode session, tree hash of the checked files.
set -euo pipefail
self="$(readlink -f "$0")"
source "$(dirname "$self")/agent-lib.sh"

usage() { awk '/^# Usage:/,/during the check\./' "$self" | sed 's/^# \{0,1\}//' >&2; exit 3; }
setup_error() { echo "agent-check: SETUP ERROR: $1" >&2; exit 3; }
fmt_secs() { printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); }
minutes() {
    [[ "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]] || setup_error "$1=$2 in the profile is not a number of minutes."
    awk -v m="$2" 'BEGIN { printf "%d", m * 60 }'
}
known() { local x="$1" y; shift; for y in "$@"; do [[ "$x" == "$y" ]] && return 0; done; return 1; }

mode=check suite=""
presets=()
tests=()
while (($#)); do
    case "$1" in
        --prebuild) mode=prebuild ;;
        --list) mode=list ;;
        --preset) [[ -n "${2:-}" ]] || usage; presets+=("$2"); shift ;;
        --suite) [[ -n "${2:-}" ]] || usage; suite="$2"; shift ;;
        -*) usage ;;
        *) tests+=("$1") ;;
    esac
    shift
done
[[ "$mode" != check && (${#tests[@]} -gt 0 || -n "$suite") ]] && usage
[[ "$mode" == prebuild && ${#presets[@]} -gt 1 ]] && usage

[[ -r "$factory_dir/vm.env" ]] || setup_error "missing $factory_dir/vm.env; run bootstrap/04-vm-facts.sh."
source "$factory_dir/vm.env"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || setup_error "not in a Git checkout; run it inside your task worktree."
id="$(basename "$top")"
{ valid_id "$id" && [[ "$(cd "$top/.." && pwd -P)" == "$(cd "$WORKTREES_DIR" 2>/dev/null && pwd -P)" ]]; } \
    || setup_error "$top is not a task worktree ($WORKTREES_DIR/<task-id>)."
[[ -r "$PROJECT_DIR/agent.env" ]] || setup_error "missing $PROJECT_DIR/agent.env; run bootstrap/08-task-workflow.sh."
source "$PROJECT_DIR/agent.env"
profile="${AGENT_CHECK_PROFILE:-$PROJECT_DIR/agent-check.conf}"
[[ -r "$profile" ]] || setup_error "missing $profile; run bootstrap/09-check-profile.sh (setup-guide.md step 9)."

# Wrapper settings; the profile can override them. The profile's interface is
# described in its header (written by bootstrap/09-check-profile.sh).
CHECK_SLOTS=5               # checks running at once on the VM, all worktrees
CHECK_JOBS=""               # build jobs per check; default min(CPUs/2, RAM GB/2)
CHECK_LOAD=""               # no new jobs above this load; default CPU count
CHECK_TIMEOUT_MIN=20        # one check, after it got its build slot
CHECK_PREBUILD_TIMEOUT_MIN=120
CHECK_WAIT_MIN=60           # waiting for a build slot or another check of the same preset
CHECK_PRESETS=()
CHECK_DEFAULT_PRESET=""
CHECK_DEFAULT_SUITE=""     # needed when the profile has more than one suite
CHECK_BUILD_PATHS=()        # empty: every change needs a build
declare -A CHECK_PARSER=()
source "$profile"
((${#CHECK_PRESETS[@]})) || setup_error "no CHECK_PRESETS in $profile."
declare -F check_build >/dev/null || setup_error "no check_build function in $profile."
declare -F check_configure >/dev/null || check_configure() { :; }
# Test suites: the profile's test_<suite> functions.
mapfile -t suites < <(declare -F | awk '$3 ~ /^test_./ { print substr($3, 6) }')
if [[ -n "$CHECK_DEFAULT_SUITE" ]]; then
    known "$CHECK_DEFAULT_SUITE" "${suites[@]}" || setup_error "CHECK_DEFAULT_SUITE=$CHECK_DEFAULT_SUITE has no test_$CHECK_DEFAULT_SUITE function in $profile."
elif ((${#suites[@]} == 1)); then
    CHECK_DEFAULT_SUITE="${suites[0]}"
elif ((${#suites[@]} > 1)); then
    setup_error "no CHECK_DEFAULT_SUITE in $profile; suites: ${suites[*]}."
fi

((${#presets[@]})) || presets=("${CHECK_DEFAULT_PRESET:-${CHECK_PRESETS[0]}}")
for p in "${presets[@]}"; do
    known "$p" "${CHECK_PRESETS[@]}" || setup_error "unknown preset '$p'; presets: ${CHECK_PRESETS[*]}."
done
[[ ${#tests[@]} -gt 0 && -z "$suite" ]] && suite="$CHECK_DEFAULT_SUITE"
if [[ -n "$suite" || ${#tests[@]} -gt 0 ]]; then
    known "$suite" "${suites[@]}" || setup_error "unknown test suite '$suite'; suites: ${suites[*]:-none}."
fi

cpus="${CPU_COUNT:-$(nproc)}"
jobs=$((cpus / 2)); mem_jobs=$((${MEM_TOTAL_GB:-0} / 2))
((mem_jobs > 0 && mem_jobs < jobs)) && jobs=$mem_jobs
export JOBS="${CHECK_JOBS:-$((jobs > 0 ? jobs : 1))}" LOAD="${CHECK_LOAD:-$cpus}" PRESET="" BUILD_DIR=""
run_s="$(minutes CHECK_TIMEOUT_MIN "$CHECK_TIMEOUT_MIN")"
[[ "$mode" == prebuild ]] && run_s="$(minutes CHECK_PREBUILD_TIMEOUT_MIN "$CHECK_PREBUILD_TIMEOUT_MIN")"
wait_s="$(minutes CHECK_WAIT_MIN "$CHECK_WAIT_MIN")"
[[ "$CHECK_SLOTS" =~ ^[1-9][0-9]*$ ]] || setup_error "CHECK_SLOTS=$CHECK_SLOTS in the profile is not a positive number."

checks="$top/.agent/check"
mkdir -p "$checks"
top_real="$(cd "$top" && pwd -P)"
# A preset's build directory, as the profile's build_dir reported it last.
dir_of() { cat "$checks/$1.dir" 2>/dev/null || true; }

if [[ "$mode" == list ]]; then
    default="${CHECK_DEFAULT_PRESET:-${CHECK_PRESETS[0]}}"
    echo "Presets (* default):"
    for p in "${CHECK_PRESETS[@]}"; do
        d="$(dir_of "$p")"
        echo "  $p$([[ "$p" == "$default" ]] && echo ' *')${d:+  (built in $d)}"
    done
    echo "Test suites (* default):"
    for s in "${suites[@]}"; do
        echo "  $s$([[ "$s" == "$CHECK_DEFAULT_SUITE" ]] && echo ' *')"
        declare -F "list_$s" >/dev/null || continue
        d="$(dir_of "$default")"
        if [[ -z "$d" ]] && declare -F build_dir >/dev/null; then
            echo "    (tests are listed after the first build of preset $default)"
            continue
        fi
        (cd "$top" && PRESET="$default" BUILD_DIR="$d" "list_$s" 2>/dev/null) | awk 'NR <= 200 { print "    " $0 } END { if (NR > 200) print "    ... and " NR - 200 " more" }'
    done
    exit 0
fi

{ ls -1t "$checks"/*.log 2>/dev/null || true; } | tail -n +20 | xargs -r rm -f
log="$checks/$(date '+%Y%m%d-%H%M%S')-$mode-$$.log"
stage_out="$checks/.stage-$$.out"
t0="$(date +%s)"
init_journal
label="$mode $(IFS=+; echo "${presets[*]}")"
timings=""

# State of the worktree including untracked files (build directories are
# ignored), to detect edits during the check; also recorded in checks.tsv.
tree_state() {
    local idx rc=0
    idx="$(mktemp)"
    cp "$(git -C "$top" rev-parse --path-format=absolute --git-path index)" "$idx" 2>/dev/null || true
    { GIT_INDEX_FILE="$idx" git -C "$top" add -A && GIT_INDEX_FILE="$idx" git -C "$top" write-tree; } 2>/dev/null || rc=1
    rm -f "$idx"
    return $rc
}

# finish <exit> <result> [parser]: print the result, record the run, exit.
finish() {
    trap - TERM INT
    local secs=$(($(date +%s) - t0)) tree="${before:-}"
    [[ -n "$tree" ]] || tree="$(tree_state)" || tree=""
    echo "agent-check: $2 ($(fmt_secs "$secs"))"
    [[ -n "${3:-}" ]] && excerpt "$3"
    rm -f "$stage_out"
    [[ -s "$log" ]] && echo "Full log: $log"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t0" "$(date +%s)" "$mode" "$(IFS=+; echo "${presets[*]}")" "$1" \
        "${OPENCODE_SESSION_ID:-}" "$tree" >> "$journal_dir/$id.checks.tsv"
    log_event "$id" "$label: $2, $(fmt_secs "$secs")${timings:+ ($timings)}"
    exit "$1"
}
trap 'finish 4 "STOPPED by a signal"' TERM INT

# excerpt compiler|ctest|pytest|generic: the part of the last step's output
# worth reading, at most 50 lines.
excerpt() {
    python3 -I - "$1" "$stage_out" <<'EOF'
import re, sys
kind, path = sys.argv[1:]
lines = open(path, errors="replace").read().splitlines()
out = []
if kind == "compiler":
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
elif kind == "ctest" and "The following tests FAILED:" in lines:
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
elif kind == "pytest":
    fails = [l for l in lines if re.match(r"^(FAILED|ERROR) ", l)]
    if fails:
        out.append(f"Failed tests ({len(fails)}):")
        out += fails[:10]
        sec = re.compile(r"^_{3,} .+ _{3,}$|^=+ short test summary")
        starts = [n for n, l in enumerate(lines) if sec.search(l)]
        for a, b in list(zip(starts, starts[1:]))[:3]:
            if lines[a].startswith("="): break
            out.append(lines[a])
            out += lines[max(a + 1, b - 15):b]
if not out:
    out = lines[-30:]
for l in out[:50]:
    print(l if len(l) <= 300 else l[:300] + " ...")
if len(out) > 50: print("... (cut; see the full log)")
EOF
}

# run_stage <name> <function> [args]: one profile function in the worktree,
# within the time left; output to $stage_out and the log.
run_stage() {
    local name="$1" rc=0 s0 left
    shift
    s0="$(date +%s)"
    left=$((deadline - s0))
    printf '\n=== %s%s: %s\n' "${PRESET:+$PRESET }" "$name" "$*" >> "$log"
    timeout -k 10 "$((left > 0 ? left : 1))" bash -c "$(declare -f); cd \"\$1\" && shift && \"\$@\"" _ "$top" "$@" \
        > "$stage_out" 2>&1 || rc=$?
    cat "$stage_out" >> "$log"
    timings+="${timings:+, }${PRESET:+$PRESET }$name $(fmt_secs $(($(date +%s) - s0)))"
    return $rc
}

# stage_failed <rc> <result> <parser> [exit]
stage_failed() {
    (($1 == 124 || $1 == 137)) && finish 4 "TIMED OUT after $((run_s / 60)) min" generic
    [[ -n "${before:-}" && "$(tree_state)" != "$before" ]] && finish 5 "FILES CHANGED during the check; run it again"
    (($1 == 3)) && finish 3 "SETUP ERROR in $2" generic
    finish "${4:-1}" "$2" "$3"
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

# accept_build_dir <dir>: the build directory the profile reported for $PRESET.
# Refused outside the worktree (tasks would share one build); kept out of Git
# through info/exclude, which all worktrees share.
accept_build_dir() {
    local d rel exclude
    d="$(cd "$top" && cd "$1" 2>/dev/null && pwd -P)" || finish 3 "SETUP ERROR: build directory '$1' of preset $PRESET does not exist"
    case "$d/" in
        "$top_real"/*) ;;
        *) finish 3 "SETUP ERROR: preset $PRESET builds outside the worktree ($d), so tasks would share one build; set its build directory inside the worktree" ;;
    esac
    BUILD_DIR="$d"
    echo "$d" > "$checks/$PRESET.dir"
    rel="${d#"$top_real"}"; rel="${rel#/}"
    [[ -z "$rel" ]] && return 0
    git -C "$top" check-ignore -q "$rel/x" && return 0
    exclude="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
    echo "/$rel/" >> "$exclude"
    log_event "$id" "added /$rel/ to $exclude (build directory of preset $PRESET)"
}

# build_preset <preset>: configure and build one preset, holding its lock.
build_preset() {
    export PRESET="$1" BUILD_DIR
    BUILD_DIR="$(dir_of "$1")"
    exec 9>"$checks/$1.lock"
    flock -w "$((wait_s - ($(date +%s) - t0) > 0 ? wait_s - ($(date +%s) - t0) : 1))" 9 \
        || finish 4 "TIMED OUT waiting $CHECK_WAIT_MIN min for another check or prebuild of preset $1"
    run_stage configure check_configure || stage_failed $? "BUILD FAILED (configure, preset $1)" "${CHECK_PARSER[build]:-compiler}"
    if declare -F build_dir >/dev/null; then
        local d
        d="$(cd "$top" && build_dir "$stage_out")" || d=""
        [[ -n "$d" ]] && accept_build_dir "$d"
        [[ -n "$BUILD_DIR" ]] || finish 3 "SETUP ERROR: build_dir in the profile reported no build directory for preset $1" generic
    fi
    # Taken after the first configure: a new build directory is ignored by Git only now.
    [[ -n "${before:-}" ]] || before="$(tree_state)" || setup_error "cannot read the worktree state."
    run_stage build check_build || stage_failed $? "BUILD FAILED (preset $1)" "${CHECK_PARSER[build]:-compiler}"
}

# Scope: what the change needs. Python and shell files get a syntax check; a
# build only if a changed file matches CHECK_BUILD_PATHS.
deadline=$((t0 + run_s))
need_build=1
if [[ "$mode" == check && -z "$suite" ]]; then
    base="$(git -C "$top" merge-base "origin/$BASE_BRANCH" HEAD 2>/dev/null)" \
        || setup_error "no common commit with origin/$BASE_BRANCH."
    mapfile -t changed < <({ git -C "$top" diff --name-only "$base"; git -C "$top" ls-files --others --exclude-standard; } | sort -u)
    [[ ${#changed[@]} -eq 0 ]] && finish 0 "OK, nothing to check (no changes against origin/$BASE_BRANCH)"
    mapfile -t scripts < <(printf '%s\n' "${changed[@]}" | grep -E '\.(py|sh)$' || true)
    if [[ ${#scripts[@]} -gt 0 ]]; then
        run_stage syntax lint_files "${scripts[@]}" || stage_failed $? "SYNTAX CHECK FAILED (Python/shell files)" generic
    fi
    if [[ ${#CHECK_BUILD_PATHS[@]} -gt 0 ]]; then
        need_build=0
        for f in "${changed[@]}"; do
            for pat in "${CHECK_BUILD_PATHS[@]}"; do
                # shellcheck disable=SC2053  # $pat is a glob pattern
                [[ "$f" == $pat ]] && { need_build=1; break 2; }
            done
        done
    fi
    ((need_build)) || finish 0 "OK, no build needed: ${#changed[@]} changed file(s), none in CHECK_BUILD_PATHS${scripts:+; syntax check passed}"
fi

# Lower priority than interactive work; inherited by every build process.
renice -n 10 -p $$ >/dev/null 2>&1 || true
ionice -c2 -n7 -p $$ >/dev/null 2>&1 || true

# One VM-wide build slot for the whole run.
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

if [[ "$mode" == prebuild ]]; then
    build_preset "${presets[0]}"
    finish 0 "OK, prebuilt preset ${presets[0]}"
fi

for p in "${presets[@]}"; do
    build_preset "$p"
    if [[ -n "$suite" ]]; then
        rc=0
        run_stage "$suite" "test_$suite" "${tests[@]}" || rc=$?
        if ((rc != 0)) && [[ "${CHECK_PARSER[$suite]:-}" == ctest ]] && grep -q 'No tests were found' "$stage_out"; then
            finish 3 "SETUP ERROR: no test in suite $suite matches: ${tests[*]}" generic
        fi
        ((rc == 0)) || stage_failed "$rc" "TESTS FAILED (preset $p, suite $suite)" "${CHECK_PARSER[$suite]:-generic}" 2
    fi
    exec 9>&-
done
[[ "$(tree_state)" == "$before" ]] || finish 5 "FILES CHANGED during the check; run it again"
what="built"
[[ -n "$suite" ]] && what="built and tested (suite $suite${tests[*]:+: ${tests[*]}})"
finish 0 "OK, preset$([[ ${#presets[@]} -gt 1 ]] && echo s) ${presets[*]} $what"
