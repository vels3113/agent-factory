#!/usr/bin/env bash
# The task workflow scripts end to end, against real OpenCode but without a
# model: bootstrap/08-task-workflow.sh, scripts/agent-task.sh, the worktree
# setup hook, the journal, report archive and ledger. The interactive UI is a
# stub that writes a report and exits (tests/lib.sh).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
sandbox
make_layout
source "$REPO/scripts/agent-lib.sh"
journal="$HOME/.agent-factory/journal"
ledger="$HOME/.agent-factory/ledger.csv"
ledger_field() { python3 -I -c 'import csv,sys; print(list(csv.reader(open(sys.argv[1])))[int(sys.argv[2])][int(sys.argv[3])])' "$ledger" "$1" "$2"; }

echo "# 08-task-workflow.sh"
check "08 runs" "$REPO/bootstrap/08-task-workflow.sh" "$P" lemon
check "08 is idempotent" bash -c "'$REPO/bootstrap/08-task-workflow.sh' '$P' lemon | grep -q 'start command already set'"
check_eq "agent.env has the base branch" "BASE_BRANCH=lemon" "$(cat "$P/agent.env")"
check ".agent/ in info/exclude" grep -qx '.agent/' "$MAIN/.git/info/exclude"
check "agent-task.sh on PATH" command -v agent-task.sh
check "08 rejects a missing base branch" bash -c "! '$REPO/bootstrap/08-task-workflow.sh' '$P' no-such-branch"

echo "# start"
check "start TASK-1" agent-task.sh start TASK-1 "First task"
wt="$P/worktrees/TASK-1"
check_eq "worktree on agent/TASK-1" "agent/TASK-1" "$(git -C "$wt" branch --show-current)"
check "branch has no upstream" bash -c "! git -C '$wt' rev-parse --abbrev-ref '@{u}'"
check_eq "branch starts at origin/lemon" "$(git -C "$MAIN" rev-parse origin/lemon)" "$(git -C "$wt" rev-parse HEAD)"
check "index row: taiga, active" bash -c "grep -q '^| \[TASK-1\](TASK-1.md) | taiga |  | First task | active |$' '$journal/index.md'"
check ".agent/ ignored by git status" test -z "$(mkdir -p "$wt/.agent"; touch "$wt/.agent/x"; git -C "$wt" status --porcelain)"
rm -rf "$wt/.agent"
agent-task.sh start TASK-1 >/dev/null
check_eq "reopen archives each session's report separately" 2 "$(ls "$HOME/.agent-factory/reports/TASK-1" | wc -l)"
check "journal links the reports" grep -q 'report: \[.*\](../reports/TASK-1/' "$journal/TASK-1.md"

echo "# local tasks"
check_eq "new allocates VM-0001" "VM-0001" "$(agent-task.sh new "Side bug" --parent TASK-1)"
check "new is logged in the parent's journal" grep -q 'side task \[VM-0001\]' "$journal/TASK-1.md"
check "start --new allocates and starts VM-0002" agent-task.sh start --new "Second"
check_eq "VM-0002 on its branch" "agent/VM-0002" "$(git -C "$P/worktrees/VM-0002" branch --show-current)"

echo "# rejections"
check "start rejects a non-ID" bash -c "! agent-task.sh start foo"
check "start rejects an unallocated VM ID" bash -c "! agent-task.sh start VM-0099"
pid="$(project_id "$MAIN")"
for name in random-name VM-0099; do
    check "hook rejects worktree '$name' created through OpenCode" bash -c "! (cd '$MAIN' && timeout $OC_TIMEOUT opencode api --standalone worktree.create -d '{\"projectID\":\"$pid\",\"name\":\"$name\"}') >/dev/null 2>&1"
    check "hook removes rejected worktree '$name'" test ! -d "$P/worktrees/$name"
done

echo "# done and ledger"
touch "$wt/dirty"
check "done refuses uncommitted changes" bash -c "! agent-task.sh done TASK-1 </dev/null"
rm "$wt/dirty"
git -C "$wt" commit -q --allow-empty -m "local work"
check "done TASK-1" bash -c "printf 'new\n7\nmaybe\naccepted\nnote, with comma\n' | agent-task.sh done TASK-1"
check "worktree removed" test ! -d "$wt"
check "branch with unpushed commits kept" git -C "$MAIN" show-ref -q --verify refs/heads/agent/TASK-1
check "done logs disk use in the journal" grep -q 'disk used: [0-9.]* GB' "$journal/TASK-1.md"
check "index status done" grep -q '^| \[TASK-1\](.* | done |$' "$journal/index.md"
check_eq "ledger has one row" 2 "$(wc -l < "$ledger")"
check_eq "ledger: 15 columns" 15 "$(python3 -I -c 'import csv,sys; print(len(list(csv.reader(open(sys.argv[1])))[1]))' "$ledger")"
check_eq "ledger: task, mode, origin" "TASK-1 interactive new" "$(ledger_field 1 0) $(ledger_field 1 2) $(ledger_field 1 3)"
check_eq "ledger: human minutes, outcome (bad answer re-asked)" "7 accepted" "$(ledger_field 1 9) $(ledger_field 1 13)"
check_eq "ledger: notes with a comma" "note, with comma" "$(ledger_field 1 14)"
agent-task.sh done TASK-1 </dev/null >/dev/null 2>&1
check_eq "rerunning done adds no row" 2 "$(wc -l < "$ledger")"
check "done VM-0002" bash -c "printf '\n\nfailed\n\n' | agent-task.sh done VM-0002"
check "branch without new commits deleted" bash -c "! git -C '$MAIN' show-ref -q --verify refs/heads/agent/VM-0002"

echo "# restart"
check "restart a done task" agent-task.sh start TASK-1
check "restart reuses the existing branch" grep -q 'on existing branch agent/TASK-1' "$journal/TASK-1.md"
check_eq "restarted task keeps its commits" "local work" "$(git -C "$wt" log -1 --format=%s)"

echo "# agent-check.sh"
check "agent-check.sh on PATH" command -v agent-check.sh
# ac <dir> [args...]: run the check in <dir>; prints the exit code, output in $T/ac.out.
ac() { (cd "$1" && shift && agent-check.sh "$@") > "$T/ac.out" 2>&1; echo $?; }
check_eq "refuses main/" 3 "$(ac "$MAIN")"
agent-task.sh start TASK-3 "Check task" >/dev/null
wt3="$P/worktrees/TASK-3"
check_eq "no build system and no check_build: setup error" 3 "$(ac "$wt3")"
check "setup error names agent.env" grep -q 'agent.env' "$T/ac.out"

# Stub build and tests: output and exit code from files in $stub.
stub="$T/stub"
mkdir -p "$stub"
cat >> "$P/agent.env" <<EOF
CHECK_TIMEOUT_MIN=\${STUB_TIMEOUT_MIN:-1}
CHECK_WAIT_MIN=\${STUB_WAIT_MIN:-1}
CHECK_SLOTS=\${STUB_SLOTS:-5}
check_build() {
    echo "preset=\$PRESET" >> "$stub/builds"
    [[ -z "\${STUB_SLEEP:-}" ]] || sleep "\$STUB_SLEEP"
    [[ -z "\${STUB_TOUCH:-}" ]] || echo "// touched" >> "\$STUB_TOUCH"
    cat "$stub/build.out" 2>/dev/null
    return "\$(cat "$stub/build.rc" 2>/dev/null || echo 0)"
}
check_test() { cat "$stub/test.out"; return "\$(cat "$stub/test.rc")"; }
EOF
check_eq "no changes: passes" 0 "$(ac "$wt3")"
check "no changes: says so, no build" bash -c "grep -q 'nothing to check' '$T/ac.out' && test ! -e '$stub/builds'"
printf 'x = (\n' > "$wt3/tool.py"
check_eq "Python-only change: syntax error fails" 1 "$(ac "$wt3")"
echo 'x = 1' > "$wt3/tool.py"
check_eq "Python-only change: passes" 0 "$(ac "$wt3")"
check "Python-only change: no build" test ! -e "$stub/builds"
echo 'int main(void) { return 0; }' > "$wt3/main.c"
git -C "$wt3" add -A && git -C "$wt3" commit -q -m "add main.c"
check_eq "C change: build passes" 0 "$(OPENCODE_SESSION_ID=ses_test ac "$wt3")"
check "pass: OK line and log path" bash -c "grep -q '^agent-check: OK, build' '$T/ac.out' && test -s \"\$(sed -n 's/^Full log: //p' '$T/ac.out')\""
ac "$wt3" --preset rel >/dev/null
check_eq "--preset reaches the check functions" "preset=rel" "$(tail -n 1 "$stub/builds")"
check "journal logs the check and its duration" grep -q 'check: OK, build, 0m0[0-9]s' "$journal/TASK-3.md"
check "checks.tsv records the OpenCode session" grep -qP '\tcheck\t\t0\tses_test$' "$journal/TASK-3.checks.tsv"

{
    echo "In file included from src/a.h:2:"
    echo "src/a.cpp:3:5: error: 'foo' was not declared in this scope"
    echo "    3 |     foo();"
    echo "      |     ^~~"
    echo "src/a.cpp:4:1: error: $(printf 'x%.0s' {1..1000})"
    for n in 5 6 7 8 9 10; do echo "src/a.cpp:$n:1: error: cascade $n"; done
    echo "src/a.cpp:3:5: error: 'foo' was not declared in this scope"
    echo "make: *** [all] Error 2"
} > "$stub/build.out"
echo 2 > "$stub/build.rc"
check_eq "build failure: exit 1" 1 "$(OPENCODE_SESSION_ID=ses_test ac "$wt3")"
check "build failure: first error with its context" bash -c "grep -q \"error: 'foo' was not declared\" '$T/ac.out' && grep -q '\^~~' '$T/ac.out'"
check_eq "build failure: 5 errors shown" 5 "$(grep -c 'error:' "$T/ac.out")"
check "build failure: the rest counted" grep -q 'and 3 more error line' "$T/ac.out"
check "build failure: long lines cut" awk 'length > 310 { exit 1 }' "$T/ac.out"
rm "$stub/build.out" "$stub/build.rc"

printf '%s\n' "    Start 1: parse_ok" "1/2 Test #1: parse_ok .........   Passed    0.01 sec" \
    "    Start 2: parse_bad" "2/2 Test #2: parse_bad ........***Failed    0.01 sec" "expected 1, got 2" "" \
    "50% tests passed, 1 tests failed out of 2" "" "The following tests FAILED:" $'\t  2 - parse_bad (Failed)' > "$stub/test.out"
echo 8 > "$stub/test.rc"
check_eq "test failure: exit 2" 2 "$(ac "$wt3" parse_ok parse_bad)"
check "test failure: failing test and its output" bash -c "grep -q 'Failed tests (1): parse_bad' '$T/ac.out' && grep -q 'expected 1, got 2' '$T/ac.out'"
check "test failure: passing test not shown" bash -c "! grep -q parse_ok '$T/ac.out'"
echo "No tests were found!!!" > "$stub/test.out"
check_eq "unknown test name: setup error" 3 "$(ac "$wt3" nope)"
echo 0 > "$stub/test.rc"
check_eq "tests pass: exit 0" 0 "$(ac "$wt3" parse_ok)"

check_eq "timeout: exit 4" 4 "$(STUB_TIMEOUT_MIN=0.05 STUB_SLEEP=10 ac "$wt3")"
check_eq "file edited during the check: exit 5" 5 "$(STUB_TOUCH="$wt3/main.c" ac "$wt3")"
git -C "$wt3" checkout -q main.c
flock "$wt3/.agent/check/default.lock" sleep 10 &
holder=$!
sleep 0.5
check_eq "same build busy: exit 4 after the wait" 4 "$(STUB_WAIT_MIN=0.05 ac "$wt3")"
check "same build busy: says why" grep -q 'another check or prebuild' "$T/ac.out"
check_eq "other preset not blocked" 0 "$(ac "$wt3" --preset rel)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
flock "$HOME/.agent-factory/check-slots/1" sleep 10 &
holder=$!
sleep 0.5
check_eq "no free build slot: exit 4" 4 "$(STUB_SLOTS=1 STUB_WAIT_MIN=0.05 ac "$wt3")"
check_eq "a second slot is free" 0 "$(STUB_SLOTS=2 ac "$wt3")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# wait_for <seconds> <command...>: until the command succeeds.
wait_for() { local n=$(($1 * 10)); shift; until "$@" >/dev/null 2>&1; do ((n-- > 0)) || return 1; sleep 0.1; done; }
STUB_SESSION_SECONDS=3 agent-task.sh start TASK-3 >/dev/null
check "start prebuilds during the session" grep -q 'prebuild: OK, prebuilt' "$journal/TASK-3.md"
STUB_SESSION_SECONDS=1 STUB_SLEEP=30 agent-task.sh start TASK-3 >/dev/null
check "prebuild stopped when the session ends" wait_for 5 grep -q 'prebuild: STOPPED' "$journal/TASK-3.md"
check "no prebuild left running" wait_for 5 bash -c "! pgrep -f 'agent-check[.]sh --prebuild'"

check "done TASK-3" bash -c "printf 'new\n3\naccepted\n\n' | agent-task.sh done TASK-3"
check_eq "ledger: check rounds and failures of OpenCode checks" "2 1" "$(ledger_field 3 10) $(ledger_field 3 11)"

echo "# agent-check.sh with CMake presets"
# Stub cmake: --preset <name> configures into <worktree>/build/<name>, preset
# "outside" into a folder next to the worktree; every call is logged.
sed -i 's/^BUILD_SYSTEM=.*/BUILD_SYSTEM=cmake/' "$HOME/.agent-factory/vm.env"
printf 'BASE_BRANCH=lemon\n' > "$P/agent.env"
export STUB_CMAKE_LOG="$T/cmake.log"
cat > "$T/bin/cmake" <<'EOF'
#!/usr/bin/env bash
echo "cmake $*" >> "$STUB_CMAKE_LOG"
if [[ "$1" == --preset ]]; then
    d="$PWD/build/$2"
    [[ "$2" == outside ]] && d="$(dirname "$PWD")/shared-build"
    mkdir -p "$d" && touch "$d/CMakeCache.txt"
    echo "-- Build files have been written to: $d"
fi
EOF
printf '#!/usr/bin/env bash\necho "ctest $*" >> "$STUB_CMAKE_LOG"\n' > "$T/bin/ctest"
chmod +x "$T/bin/cmake" "$T/bin/ctest"
agent-task.sh start TASK-4 "Preset task" >/dev/null
wt4="$P/worktrees/TASK-4"
wait_for 10 bash -c "! pgrep -f 'agent-check[.]sh --prebuild'"
echo '{}' > "$wt4/CMakePresets.json"
echo 'int main(void) { return 0; }' > "$wt4/main.c"
git -C "$wt4" add -A && git -C "$wt4" commit -q -m "add main.c and presets"
check_eq "CMake without a preset: setup error" 3 "$(ac "$wt4")"
check "no preset: says how to set one" grep -q 'pass --preset <name>, or set CHECK_PRESET' "$T/ac.out"
echo 'CHECK_PRESET=dev' >> "$P/agent.env"
: > "$STUB_CMAKE_LOG"
check_eq "preset build passes" 0 "$(ac "$wt4" t1)"
check "configures with the preset, no -B" grep -qx 'cmake --preset dev.*' "$STUB_CMAKE_LOG"
check "configure does not override binaryDir" bash -c "! grep -q -- '--preset dev.* -B' '$STUB_CMAKE_LOG'"
check "builds in the preset's binaryDir" grep -q "^cmake --build $wt4/build/dev " "$STUB_CMAKE_LOG"
check "tests in the preset's binaryDir" grep -q "^ctest --test-dir $wt4/build/dev " "$STUB_CMAKE_LOG"
check "build directory added to info/exclude" grep -qx '/build/dev/' "$MAIN/.git/info/exclude"
check "worktree status stays clean" test -z "$(git -C "$wt4" status --porcelain)"
ac "$wt4" >/dev/null
check_eq "next check does not configure again" 1 "$(grep -c -- '--preset dev' "$STUB_CMAKE_LOG")"
touch -d 'now + 1 minute' "$wt4/CMakePresets.json"
ac "$wt4" >/dev/null
check_eq "changed preset file: configures again" 2 "$(grep -c -- '--preset dev' "$STUB_CMAKE_LOG")"
check_eq "preset outside the worktree: setup error" 3 "$(ac "$wt4" --preset outside)"
check "outside: says why" grep -q 'builds outside the worktree' "$T/ac.out"

finish
