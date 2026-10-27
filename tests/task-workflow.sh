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
# wait_for <seconds> <command...>: until the command succeeds.
wait_for() { local n=$(($1 * 10)); shift; until "$@" >/dev/null 2>&1; do ((n-- > 0)) || return 1; sleep 0.1; done; }
check_eq "refuses main/" 3 "$(ac "$MAIN")"
agent-task.sh start TASK-3 "Check task" >/dev/null
wt3="$P/worktrees/TASK-3"
check_eq "no profile: setup error" 3 "$(ac "$wt3")"
check "no profile: names the bootstrap step" grep -q '09-check-profile.sh' "$T/ac.out"

# Stub profile: two presets, a ctest-like and a pytest-like suite; output and
# exit codes come from files in $stub.
stub="$T/stub"
mkdir -p "$stub"
echo 0 > "$stub/test.rc"
echo 0 > "$stub/py.rc"
cat > "$P/agent-check.conf" <<EOF
CHECK_PRESETS=(dev rel)
CHECK_DEFAULT_PRESET=dev
CHECK_DEFAULT_SUITE=unit
declare -A CHECK_PARSER=([unit]=ctest [py]=pytest)
CHECK_BUILD_PATHS=('*.c')
CHECK_TIMEOUT_MIN=\${STUB_TIMEOUT_MIN:-1}
CHECK_WAIT_MIN=\${STUB_WAIT_MIN:-1}
CHECK_SLOTS=\${STUB_SLOTS:-5}
check_build() {
    echo "preset=\$PRESET" >> "$stub/builds"
    [[ -z "\${STUB_SLEEP:-}" ]] || sleep "\$STUB_SLEEP"
    [[ -z "\${STUB_TOUCH:-}" ]] || echo "// touched" >> "\$STUB_TOUCH"
    cat "$stub/build.out" 2>/dev/null
    [[ "\$PRESET" == "\${STUB_FAIL_PRESET:-}" ]] && return 2
    return "\$(cat "$stub/build.rc" 2>/dev/null || echo 0)"
}
test_unit() { echo "unit:\$*" >> "$stub/tests"; cat "$stub/test.out" 2>/dev/null; return "\$(cat "$stub/test.rc")"; }
test_py() { cat "$stub/py.out" 2>/dev/null; return "\$(cat "$stub/py.rc")"; }
list_unit() { printf 'parse_ok\nparse_bad\n'; }
EOF
check_eq "no changes: passes" 0 "$(ac "$wt3")"
check "no changes: says so, no build" bash -c "grep -q 'nothing to check' '$T/ac.out' && test ! -e '$stub/builds'"
printf 'x = (\n' > "$wt3/tool.py"
check_eq "Python syntax error fails" 1 "$(ac "$wt3")"
echo 'x = 1' > "$wt3/tool.py"
echo '# notes' > "$wt3/README.md"
check_eq "only files outside CHECK_BUILD_PATHS: passes" 0 "$(ac "$wt3")"
check "outside CHECK_BUILD_PATHS: no build, says why" bash -c "grep -q 'no build needed' '$T/ac.out' && test ! -e '$stub/builds'"
echo 'int main(void) { return 0; }' > "$wt3/main.c"
git -C "$wt3" add -A && git -C "$wt3" commit -q -m "add main.c"
check_eq "C change: build passes" 0 "$(OPENCODE_SESSION_ID=ses_test ac "$wt3")"
check "pass: OK line and log path" bash -c "grep -q '^agent-check: OK, preset dev built' '$T/ac.out' && test -s \"\$(sed -n 's/^Full log: //p' '$T/ac.out')\""
check_eq "default preset built" "preset=dev" "$(tail -n 1 "$stub/builds")"
check "journal logs the check with step times" grep -q 'check dev: OK, preset dev built, 0m0[0-9]s (.*dev configure 0m0[0-9]s, dev build 0m0[0-9]s)' "$journal/TASK-3.md"
check "checks.tsv: session and tree hash" grep -qP '\tcheck\tdev\t0\tses_test\t[0-9a-f]{40}$' "$journal/TASK-3.checks.tsv"
check_eq "tree hash is the committed tree" "$(git -C "$wt3" rev-parse 'HEAD^{tree}')" "$(tail -n 1 "$journal/TASK-3.checks.tsv" | cut -f 7)"
check_eq "two presets: both built" 0 "$(ac "$wt3" --preset dev --preset rel)"
check_eq "two presets: in order" "preset=dev preset=rel" "$(tail -n 2 "$stub/builds" | paste -sd ' ')"
check_eq "two presets: stops at the first failure" 1 "$(STUB_FAIL_PRESET=dev ac "$wt3" --preset dev --preset rel)"
check_eq "two presets: second not built after a failure" "preset=dev" "$(tail -n 1 "$stub/builds")"
check_eq "unknown preset: setup error" 3 "$(ac "$wt3" --preset nope)"
check "unknown preset: lists the presets" grep -q 'presets: dev rel' "$T/ac.out"
check_eq "--list" 0 "$(ac "$wt3" --list)"
check "--list: presets, default marked" grep -qx '  dev \*' "$T/ac.out"
check "--list: suites and their tests" bash -c "grep -qx '  unit \*' '$T/ac.out' && grep -qx '    parse_bad' '$T/ac.out'"
check_eq "unknown suite: setup error" 3 "$(ac "$wt3" --suite nope)"
check "unknown suite: lists the test_ functions" grep -q 'suites: py unit' "$T/ac.out"
sed -i '/^CHECK_DEFAULT_SUITE=/d' "$P/agent-check.conf"
check_eq "two suites, no CHECK_DEFAULT_SUITE: setup error" 3 "$(ac "$wt3" --list)"
echo 'CHECK_DEFAULT_SUITE=unit' >> "$P/agent-check.conf"

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
check_eq "named tests go to the default suite" "unit:parse_ok parse_bad" "$(tail -n 1 "$stub/tests")"
check "test failure: failing test and its output" bash -c "grep -q 'Failed tests (1): parse_bad' '$T/ac.out' && grep -q 'expected 1, got 2' '$T/ac.out'"
check "test failure: passing test not shown" bash -c "! grep -q parse_ok '$T/ac.out'"
echo "No tests were found!!!" > "$stub/test.out"
check_eq "unknown test name: setup error" 3 "$(ac "$wt3" nope)"
echo 0 > "$stub/test.rc"
check_eq "--suite without names: whole suite" 0 "$(ac "$wt3" --suite unit)"
check_eq "--suite without names: no test names passed" "unit:" "$(tail -n 1 "$stub/tests")"
printf '%s\n' "_____ test_parse _____" "    assert parse('a') == 1" "E   assert 2 == 1" \
    "=========================== short test summary info ============================" \
    "FAILED tests/test_parse.py::test_parse - assert 2 == 1" > "$stub/py.out"
echo 1 > "$stub/py.rc"
check_eq "pytest suite failure: exit 2" 2 "$(ac "$wt3" --suite py test_parse)"
check "pytest failure: summary and assertion" bash -c "grep -q '^FAILED tests/test_parse.py::test_parse' '$T/ac.out' && grep -q 'E   assert 2 == 1' '$T/ac.out'"
echo 0 > "$stub/py.rc"
check_eq "unknown suite: setup error" 3 "$(ac "$wt3" --suite nope)"

check_eq "timeout: exit 4" 4 "$(STUB_TIMEOUT_MIN=0.05 STUB_SLEEP=10 ac "$wt3")"
check_eq "file edited during the check: exit 5" 5 "$(STUB_TOUCH="$wt3/main.c" ac "$wt3")"
git -C "$wt3" checkout -q main.c
flock "$wt3/.agent/check/dev.lock" sleep 10 &
holder=$!
sleep 0.5
check_eq "same preset busy: exit 4 after the wait" 4 "$(STUB_WAIT_MIN=0.05 ac "$wt3")"
check "same preset busy: says why" grep -q 'another check or prebuild of preset dev' "$T/ac.out"
check_eq "other preset not blocked" 0 "$(ac "$wt3" --preset rel)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
flock "$HOME/.agent-factory/check-slots/1" sleep 10 &
holder=$!
sleep 0.5
check_eq "no free build slot: exit 4" 4 "$(STUB_SLOTS=1 STUB_WAIT_MIN=0.05 ac "$wt3")"
check_eq "a second slot is free" 0 "$(STUB_SLOTS=2 ac "$wt3")"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

STUB_SESSION_SECONDS=3 agent-task.sh start TASK-3 >/dev/null
check "start prebuilds the default preset during the session" grep -q 'prebuild dev: OK, prebuilt preset dev' "$journal/TASK-3.md"
STUB_SESSION_SECONDS=1 STUB_SLEEP=30 agent-task.sh start TASK-3 >/dev/null
check "prebuild stopped when the session ends" wait_for 5 grep -q 'prebuild dev: STOPPED' "$journal/TASK-3.md"
check "no prebuild left running" wait_for 5 bash -c "! pgrep -f 'agent-check[.]sh --prebuild'"

check "done TASK-3" bash -c "printf 'new\n3\naccepted\n\n' | agent-task.sh done TASK-3"
check_eq "ledger: check rounds and failures of OpenCode checks" "2 1" "$(ledger_field 3 10) $(ledger_field 3 11)"

# Agent minutes from a fake session export (times in ms): a prompt with a
# 10-minute tool call (an approval wait), then a wake-up by a finished
# background command with two overlapping tool calls. Model time: 2 + 1 min.
fake="$T/fake-sessions"
mkdir -p "$fake/bin"
cat > "$fake/list.json" <<EOF
[{"id": "ses_a", "directory": "$P/worktrees/TASK-9"}, {"id": "ses_b", "directory": "$MAIN"}]
EOF
cat > "$fake/ses_a.json" <<'EOF'
{"info": {"id": "ses_a", "cost": 0.1, "model": {"id": "vendor/m", "providerID": "openrouter"}},
 "messages": [
  {"type": "user", "time": {"created": 0}},
  {"type": "assistant", "time": {"created": 1000}, "content": [
    {"type": "tool", "time": {"created": 60000, "ran": 60000, "completed": 660000}}]},
  {"type": "idle", "time": {"created": 720000}},
  {"type": "synthetic", "time": {"created": 2000000}},
  {"type": "assistant", "time": {"created": 2001000}, "content": [
    {"type": "text", "text": "two calls"},
    {"type": "tool", "time": {"created": 2030000, "ran": 2030000, "completed": 2090000}},
    {"type": "tool", "time": {"created": 2060000, "ran": 2060000, "completed": 2120000}}]},
  {"type": "idle", "time": {"created": 2150000}}]}
EOF
cat > "$fake/bin/opencode" <<EOF
#!/usr/bin/env bash
case "\$2" in
    list) cat "$fake/list.json" ;;
    export) cat "$fake/\$4.json" ;;
esac
EOF
chmod +x "$fake/bin/opencode"
(PATH="$fake/bin:$PATH" ledger_row "$MAIN" "$P/worktrees/TASK-9" TASK-9 interactive new 5 accepted "") >/dev/null
check_eq "ledger: only the worktree's session" "ses_a" "$(ledger_field -1 6)"
check_eq "ledger: agent minutes count wake-ups, not tool calls" "3.0" "$(ledger_field -1 8)"

echo "# CMake profile from 09-check-profile.sh"
# Stub cmake: --preset <name> configures into <worktree>/build/<name>, preset
# "outside" into a folder next to the worktree; every call is logged.
export STUB_CMAKE_LOG="$T/cmake.log"
cat > "$T/bin/cmake" <<'EOF'
#!/usr/bin/env bash
echo "cmake $*" >> "$STUB_CMAKE_LOG"
case "$1" in
    --preset)
        d="$PWD/build/$2"
        [[ "$2" == outside ]] && d="$(dirname "$PWD")/shared-build"
        mkdir -p "$d" && touch "$d/CMakeCache.txt"
        echo "-- Build files have been written to: $d" ;;
    --list-presets=configure)
        printf 'Available configure presets:\n\n  "dev" - Dev\n  "rel" - Release\n' ;;
esac
EOF
printf '#!/usr/bin/env bash\necho "ctest $*" >> "$STUB_CMAKE_LOG"\n' > "$T/bin/ctest"
chmod +x "$T/bin/cmake" "$T/bin/ctest"
sed -i 's/^BUILD_SYSTEM=.*/BUILD_SYSTEM=cmake/' "$HOME/.agent-factory/vm.env"
rm "$P/agent-check.conf"
"$REPO/bootstrap/09-check-profile.sh" "$P" >/dev/null
check "new CMake profile: presets left TODO without CMakePresets.json" grep -qx 'CHECK_PRESETS=(TODO)' "$MAIN/agent-check.draft.conf"
sed -e 's/^CHECK_PRESETS=(TODO)/CHECK_PRESETS=(dev outside)/' -e 's/^CHECK_DEFAULT_PRESET=TODO/CHECK_DEFAULT_PRESET=dev/' \
    "$MAIN/agent-check.draft.conf" > "$P/agent-check.conf"
rm "$MAIN/agent-check.draft.conf"
agent-task.sh start TASK-4 "Preset task" >/dev/null
wt4="$P/worktrees/TASK-4"
# The prebuild may start after the session ended: wait for its journal line.
wait_for 10 grep -q "prebuild dev: " "$journal/TASK-4.md"
wait_for 10 bash -c "! pgrep -f 'agent-check[.]sh --prebuild'"
echo '{}' > "$wt4/CMakePresets.json"
echo 'int main(void) { return 0; }' > "$wt4/main.c"
git -C "$wt4" add -A && git -C "$wt4" commit -q -m "add main.c and presets"
: > "$STUB_CMAKE_LOG"
check_eq "template: build and tests pass" 0 "$(ac "$wt4" t1)"
check "template: configures with the preset, no -B" bash -c "grep -qx 'cmake --preset dev.*' '$STUB_CMAKE_LOG' && ! grep -q -- '--preset dev.* -B' '$STUB_CMAKE_LOG'"
check "template: builds in the preset's binaryDir" grep -q "^cmake --build $wt4/build/dev " "$STUB_CMAKE_LOG"
check "template: tests in the preset's binaryDir, named test only" bash -c "grep -F 'ctest --test-dir $wt4/build/dev ' '$STUB_CMAKE_LOG' | grep -qF -- ' -R ^(t1)\$'"
check "build directory added to info/exclude" grep -qx '/build/dev/' "$MAIN/.git/info/exclude"
check "worktree status stays clean" test -z "$(git -C "$wt4" status --porcelain)"
ac "$wt4" >/dev/null
check_eq "template: next check does not configure again" 1 "$(grep -c -- '--preset dev' "$STUB_CMAKE_LOG")"
touch -d 'now + 1 minute' "$wt4/CMakePresets.json"
ac "$wt4" >/dev/null
check_eq "template: changed presets: configures again" 2 "$(grep -c -- '--preset dev' "$STUB_CMAKE_LOG")"
check_eq "preset outside the worktree: setup error" 3 "$(ac "$wt4" --preset outside)"
check "outside: says why" grep -q 'builds outside the worktree' "$T/ac.out"

echo "# 09-check-profile.sh"
mv "$P/agent-check.conf" "$T/old-profile.conf"
echo '{}' > "$MAIN/CMakePresets.json"
printf 'stage("build") { sh "cmake --preset rel && cmake --build --preset rel" }\n' > "$MAIN/Jenkinsfile"
git -C "$MAIN" add CMakePresets.json Jenkinsfile && git -C "$MAIN" commit -q -m "presets and Jenkinsfile"
draft="$MAIN/agent-check.draft.conf"
check "09 drafts a profile" bash -c "'$REPO/bootstrap/09-check-profile.sh' '$P' > '$T/09.out'"
check "draft: the presets the Jenkinsfile builds" grep -qx 'CHECK_PRESETS=(rel)' "$draft"
check "draft: default preset" grep -qx 'CHECK_DEFAULT_PRESET=rel' "$draft"
check "draft: notes all configure presets" grep -q 'configure presets: dev rel' "$draft"
check "draft kept out of Git" test -z "$(git -C "$MAIN" status --porcelain)"
check "09 prints the OpenCode prompt" grep -q 'Complete agent-check.draft.conf' "$T/09.out"
check "prompt: drop the profile's ccache when the repo uses it" grep -q "already use ccache" <(tr -s " \n" " " < "$T/09.out")
echo '# my edit' >> "$draft"
"$REPO/bootstrap/09-check-profile.sh" "$P" >/dev/null
check "09 keeps an existing draft" grep -qx '# my edit' "$draft"
sed -i 's/^CHECK_DEFAULT_PRESET=rel/CHECK_DEFAULT_PRESET=TODO/' "$draft"
check "validate refuses TODO values" bash -c "! '$REPO/bootstrap/09-check-profile.sh' '$P' --validate >/dev/null 2>&1"
sed -i 's/^CHECK_DEFAULT_PRESET=TODO/CHECK_DEFAULT_PRESET=rel/' "$draft"
check "validate builds and installs" bash -c "'$REPO/bootstrap/09-check-profile.sh' '$P' --validate > '$T/09v.out' 2>&1"
check "validate: built the default preset" grep -q '^cmake --preset rel' "$STUB_CMAKE_LOG"
check "validate: profile installed, draft gone" bash -c "grep -qx '# my edit' '$P/agent-check.conf' && test ! -e '$draft'"
vid="$(grep -o '^| \[VM-[0-9]*\](VM-[0-9]*.md) | local |  | agent-check profile validation | done |' "$journal/index.md" | grep -o 'VM-[0-9]*' | head -n 1)"
check "validate: task done in the journal" test -n "$vid"
check "validate: worktree and branch removed" bash -c "test ! -d '$P/worktrees/$vid' && ! git -C '$MAIN' show-ref -q --verify 'refs/heads/agent/$vid'"
check "validate: logs kept" bash -c "ls '$HOME/.agent-factory/reports/$vid/'*.log"
sed -i 's/^BUILD_SYSTEM=.*/BUILD_SYSTEM=make/' "$HOME/.agent-factory/vm.env"
mv "$P/agent-check.conf" "$T/cmake-profile.conf"
"$REPO/bootstrap/09-check-profile.sh" "$P" >/dev/null
check "new Make profile: builds with make" grep -q '^check_build() { with_ccache; make ' "$draft"
check "new Make profile: valid bash" bash -n "$draft"

finish
