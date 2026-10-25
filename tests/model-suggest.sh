#!/usr/bin/env bash
# scripts/model-suggest.sh on a hand-made catalog, ledger and opencode.jsonc;
# no network and no OpenCode.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
T="$(mktemp -d)"
[[ "${KEEP:-}" == 1 ]] || trap 'rm -rf "$T"' EXIT
export AGENT_FACTORY_DIR="$T/factory"
export MODEL_SUGGEST_CATALOG="$T/models.json"
# One million tokens of each kind except cache write: est$/task is the sum of the per-1M prices.
export MODEL_SUGGEST_MIX=1000000,1000000,0,1000000
export MODEL_SUGGEST_FLOOR_MAIN=40 MODEL_SUGGEST_FLOOR_CHEAP=20 MODEL_SUGGEST_TOP=6
mkdir -p "$AGENT_FACTORY_DIR" "$T/demo"
echo "PROJECT_DIR=$T/demo" > "$AGENT_FACTORY_DIR/vm.env"
"$REPO/bootstrap/02-init-ledger.sh" >/dev/null

python3 -I - "$MODEL_SUGGEST_CATALOG" <<'EOF'
import datetime, json, sys
soon = (datetime.date.today() + datetime.timedelta(days=10)).isoformat()
late = (datetime.date.today() + datetime.timedelta(days=90)).isoformat()
def m(id, intel=None, prompt=1, completion=1, cache=None, ctx=200000, tools=True, **extra):
    p = {"prompt": str(prompt / 1e6), "completion": str(completion / 1e6)}
    if cache is not None: p["input_cache_read"] = str(cache / 1e6)
    d = {"id": id, "context_length": ctx, "pricing": p, "expiration_date": None,
         "supported_parameters": ["max_tokens"] + (["tools", "tool_choice"] if tools else []),
         "benchmarks": {"artificial_analysis": {"intelligence_index": intel, "coding_index": None, "agentic_index": None}}}
    d.update(extra)
    return d
models = [
    m("a/main-good", 50, 2, 8, 0.2),              # 10.2
    m("a/main-cheap", 48, 1, 4, 0.1),             # 5.1, untested
    m("b/main-accepted", 45, 3, 15, 0.5),         # 18.5, accepted in the ledger; 7th in the cheap tier
    m("anthropic/claude-x", 55, 3, 15, 0.3),      # 18.3, no vendor filter
    m("c/low", 25, 0.1, 0.4),                     # 0.6 (no cache price: full input price), cheap tier only
    m("c/too-low", 10, 0.05, 0.1),                # below both floors
    m("d/notools", 50, 0.5, 1, tools=False),
    m("e/smallctx", 50, 0.5, 1, ctx=32000),
    m("f/expiring", 50, 0.5, 1, expiration_date=soon),
    m("f/later", 50, 2, 8, 0.2, expiration_date=late),  # 10.2
    m("g/peak", 42, 1, 2, 0.1),                   # base 3.1, peak 6.2
    m("h/unrated", None, 0.2, 1),                 # no index
    m("i/variable", 50, -1, -1),                  # price unknown
    m("openrouter/auto", 50, 0.01, 0.01),
    m("~a/main-latest", 50, 0.01, 0.01),
    m("a/main-good:batch", 50, 0.01, 0.01),
    m("x/coder:free", 30, 0, 0),
]
models[10]["pricing"]["overrides"] = [
    {"utc_days": ["saturday"], "prompt": "0.000001", "completion": "0.000002", "input_cache_read": "0.0000001"},
    {"utc_days": ["monday"], "utc_start": 100, "utc_end": 400,
     "prompt": "0.000002", "completion": "0.000004", "input_cache_read": "0.0000002"}]
del models[11]["benchmarks"]
json.dump({"data": models}, open(sys.argv[1], "w"))
EOF

ledger="$AGENT_FACTORY_DIR/ledger.csv"
cat >> "$ledger" <<'EOF'
VM-1,2026-10-20,interactive,new,b/main-accepted,openrouter,s1,0.5000,10.0,5,1,0,,accepted,
VM-2,2026-10-21,interactive,new,b/main-accepted,openrouter,s2,0.3000,8.0,9,2,1,,failed,
VM-3,2026-10-22,interactive,new,a/main-good+c/low,openrouter,s3 s4,0.2000,6.0,4,1,0,,reworked,
EOF

# The real template, with build on a variant and explore on a removed model.
sed -e '0,/\/\/ "model": "openrouter\/TODO_MAIN_MODEL",/s||"model": "openrouter/a/main-good#high",|' \
    -e 's|// "model": "openrouter/TODO_CHEAP_MODEL",|"model": "openrouter/gone/model",|' \
    "$REPO/templates/opencode.jsonc" > "$T/demo/opencode.jsonc"

echo "# report"
out="$("$REPO/scripts/model-suggest.sh" 2>&1)"
rc=$?
check_eq "exits 0" 0 "$rc"
[[ "${VERBOSE:-}" == 1 || $rc -ne 0 ]] && echo "$out"
main="$(sed -n '/^MAIN tier/,/^$/p' <<<"$out")"
cheap="$(sed -n '/^CHEAP tier/,/^$/p' <<<"$out")"
paste="$(sed -n '/^Paste into/,/^$/p' <<<"$out")"
smoke="$(sed -n '/^Untested candidates/,$p' <<<"$out")"
row() { grep -E "^ +[0-9]+ +$1 " <<<"$2"; }

for id in d/notools e/smallctx f/expiring i/variable openrouter/auto '~a/main-latest' a/main-good:batch c/too-low; do
    check "filtered: $id" bash -c '! grep -qF -- " $1 " <<<"$2"' _ "$id" "$main$cheap"
done
check "kept: expiry beyond 30 days" row f/later "$main"
check "kept: anthropic model" row anthropic/claude-x "$main"
check "below main floor, in cheap tier" bash -c '! grep -qF " c/low " <<<"$1" && grep -qF " c/low " <<<"$2"' _ "$main" "$cheap"
check_eq "main tier order by cost" "a/main-cheap g/peak a/main-good f/later anthropic/claude-x b/main-accepted" \
    "$(grep -E '^ +[0-9]+ ' <<<"$main" | awk '{print $2}' | xargs)"
check "peak price used" bash -c 'grep -E " g/peak +6\.20 " <<<"$1"' _ "$main"
check "missing cache price counts as input" bash -c 'grep -E " c/low +0\.60 " <<<"$1"' _ "$cheap"
check "unrated line" bash -c 'grep -E "^  unrated.*h/unrated" <<<"$1"' _ "$main"
check "free model only as explore row" bash -c 'grep -E "free.*x/coder:free" <<<"$1" && ! grep -qF "x/coder:free" <<<"$2"' _ "$cheap" "$main"
check "ledger: accepted/all and cost per accepted" bash -c 'grep -E " b/main-accepted .* 1/2 +0\.80" <<<"$1"' _ "$main"
check "ledger: shared row" bash -c 'grep -E " a/main-good .* 0/1 .*shared" <<<"$1"' _ "$main"
check "ledger: no rows is untested" bash -c 'grep -E " a/main-cheap .* untested" <<<"$1"' _ "$main"
check "current build model found despite variant" bash -c 'grep -E "current build: openrouter/a/main-good#high +rank 3," <<<"$1"' _ "$main"
check "current model missing from catalog" bash -c 'grep -E "current explore: openrouter/gone/model +not in catalog" <<<"$1"' _ "$cheap"
check "paste: accepted model over cheaper untested" bash -c 'grep -E "\"build\": \{ \"model\": \"openrouter/b/main-accepted\" \}" <<<"$1"' _ "$paste"
check "paste: pick without accepted task marked" bash -c 'grep -E "\"explore\": \{ \"model\": \"openrouter/c/low\" \}, // no accepted task yet" <<<"$1"' _ "$paste"
head -n 1 "$ledger" > "$T/empty.csv"
check "paste: untested pick marked (empty ledger)" bash -c 'mkdir -p "$1/f2" && cp "$1/empty.csv" "$1/f2/ledger.csv" && AGENT_FACTORY_DIR="$1/f2" "$2/scripts/model-suggest.sh" 2>/dev/null | grep -E "\"build\": \{ \"model\": \"openrouter/a/main-cheap\" \}, // untested"' _ "$T" "$REPO"
check "smoke command for untested top 3" bash -c 'grep -F "AGENT_TEST_MODEL=openrouter/a/main-cheap tests/run.sh --model" <<<"$1"' _ "$smoke"
check "no smoke command for tested model" bash -c '! grep -F "openrouter/b/main-accepted " <<<"$1"' _ "$smoke"

echo "# errors"
check "no ledger: names the bootstrap step" bash -c 'AGENT_FACTORY_DIR="$1/none" "$2/scripts/model-suggest.sh" 2>&1 | grep -q "02-init-ledger.sh"' _ "$T" "$REPO"
echo '{"data": [{"id": "a/b"}]}' > "$T/bad.json"
check "missing field: named in the error" bash -c 'MODEL_SUGGEST_CATALOG="$1/bad.json" "$2/scripts/model-suggest.sh" 2>&1 | grep -q "context_length"' _ "$T" "$REPO"
check "missing field: exit 1" bash -c '! MODEL_SUGGEST_CATALOG="$1/bad.json" "$2/scripts/model-suggest.sh" >/dev/null 2>&1' _ "$T" "$REPO"

finish
