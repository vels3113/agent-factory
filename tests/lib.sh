# Shared test helpers; sourced by the tests/*.sh suites, not run.
# Every suite runs in a throwaway sandbox: its own HOME, OpenCode data, projects
# folder and Git origin, so your real setup is never touched. OpenCode is
# installed once per version into a cache folder and reused.
#   OPENCODE_VERSION   version under test (default: the pinned 2.1.3)
#   AGENT_TEST_CACHE   cache for OpenCode installs (default ~/.cache/agent-factory-tests)
#   KEEP=1             keep the sandbox for inspection

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OC_VERSION="${OPENCODE_VERSION:-2.1.3}"
OC_TIMEOUT=120
pass=0
fail=0

ok() { echo "ok    $1"; pass=$((pass + 1)); }
not_ok() { echo "FAIL  $1${2:+ ($2)}"; fail=$((fail + 1)); }
# check <name> <command...>: passes when the command succeeds.
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else not_ok "$name"; fi; }
# check_eq <name> <expected> <actual>
check_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else not_ok "$1" "expected '$2', got '$3'"; fi; }
finish() {
    echo "$pass passed, $fail failed"
    [[ "${KEEP:-}" == 1 ]] && echo "Sandbox kept: $T"
    [[ $fail -eq 0 ]]
}

# install_opencode: puts the version under test into the cache; prints its bin dir.
install_opencode() {
    local cache="${AGENT_TEST_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/agent-factory-tests}/opencode-$OC_VERSION"
    local bin="$cache/.opencode/bin"
    if [[ ! -x "$bin/opencode" ]]; then
        mkdir -p "$cache"
        curl -fsSL https://opencode.ai/v2/install -o "$cache/install.sh" || return 1
        HOME="$cache" SHELL=/bin/sh bash "$cache/install.sh" --version "$OC_VERSION" >/dev/null || return 1
    fi
    echo "$bin"
}

# sandbox: fresh HOME and PATH. $T/bin comes first and holds test stubs: an
# `opencode` that stands in for the interactive UI (writes a report, exits) and
# passes every subcommand to the real binary. STUB_SESSION_SECONDS keeps the
# stub session open that long (default 0).
sandbox() {
    local oc_bin
    oc_bin="$(install_opencode)" || { echo "Cannot install OpenCode $OC_VERSION" >&2; exit 2; }
    T="$(mktemp -d)"
    if [[ "${KEEP:-}" == 1 ]]; then
        trap 'opencode service stop >/dev/null 2>&1' EXIT
    else
        trap 'opencode service stop >/dev/null 2>&1; rm -rf "$T"' EXIT
    fi
    export HOME="$T/home" AGENT_PROJECTS_DIR="$T/projects"
    unset AGENT_FACTORY_DIR AGENT_SECRETS_DIR
    mkdir -p "$HOME/.config/opencode" "$T/bin" "$AGENT_PROJECTS_DIR"
    echo '{ "update": "disable" }' > "$HOME/.config/opencode/opencode.jsonc"
    git config --global user.name "Agent Test"
    git config --global user.email "agent-test@example.invalid"
    cat > "$T/bin/opencode" <<EOF
#!/usr/bin/env bash
if [[ \$# -eq 1 && -d "\$1" ]]; then
    mkdir -p "\$1/.agent" && echo "# stub session report" > "\$1/.agent/report.md"
    sleep "\${STUB_SESSION_SECONDS:-0}"
    exit 0
fi
exec "$oc_bin/opencode" "\$@"
EOF
    chmod +x "$T/bin/opencode"
    export PATH="$T/bin:$HOME/.local/bin:$oc_bin:$PATH"
    # Commands without --standalone (debug config, the UI) use the background
    # service, which has a fixed default port; give the sandbox its own.
    opencode service set port "$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')" >/dev/null
    P="$AGENT_PROJECTS_DIR/demo"
    MAIN="$P/main"
}

# make_layout: origin repo with base branch lemon, ledger, project layout (02, 03, 04).
make_layout() {
    git init -q --bare -b lemon "$T/origin.git"
    git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
    git -C "$T/seed" commit -q --allow-empty -m init
    git -C "$T/seed" push -q origin HEAD:lemon
    "$REPO/bootstrap/02-init-ledger.sh" >/dev/null
    "$REPO/bootstrap/03-project-layout.sh" demo "file://$T/origin.git" >/dev/null 2>&1
    "$REPO/bootstrap/04-vm-facts.sh" "$P" >/dev/null 2>&1
}

# oc_api <args...>: `opencode api` against a private server, run from main/.
oc_api() { (cd "$MAIN" && timeout "$OC_TIMEOUT" opencode api --standalone "$@"); }
