"""A small OpenRouter model catalog for tests/model-suggest.sh, covering each
filter and ranking rule. Usage: model-catalog.py <output.json>
"""
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
