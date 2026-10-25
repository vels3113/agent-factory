"""Model suggestions per agent tier; run by model-suggest.sh (settings documented there).
Design: model-suggest-design.md. Python 3.10 standard library only.
Usage: model_suggest.py <ledger.csv> [<opencode.jsonc>]"""
import csv, datetime, json, os, re, sys, urllib.request

CATALOG_URL = "https://openrouter.ai/api/v1/models"
TIERS = [("MAIN", ["build", "plan"]), ("CHEAP", ["explore", "ci-fix"])]
PRICE_KINDS = ["input_cache_read", "prompt", "input_cache_write", "completion"]  # order of MODEL_SUGGEST_MIX
REQUIRED = ["id", "context_length", "supported_parameters", "pricing.prompt", "pricing.completion"]
EXPIRY_DAYS = 30
UNRATED_ROWS = 3
FREE_ROWS = 3
SMOKE_TOP = 3


def die(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def setting(name, default):
    return os.environ.get("MODEL_SUGGEST_" + name) or default


def load_catalog():
    path = os.environ.get("MODEL_SUGGEST_CATALOG")
    if path:
        source = f"read from {path}"
        try:
            data = json.load(open(path))
        except (OSError, ValueError) as e:
            die(f"Cannot read catalog {path}: {e}")
    else:
        source = "fetched " + datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        req = urllib.request.Request(CATALOG_URL, headers={"User-Agent": "agent-factory model-suggest"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = json.load(r)
        except (OSError, ValueError) as e:
            die(f"Cannot fetch {CATALOG_URL}: {e}")
    models = data.get("data") if isinstance(data, dict) else None
    if not isinstance(models, list):
        die("Catalog: no 'data' list (the OpenRouter API changed?)")
    for m in models:
        for field in REQUIRED:
            v = m
            for k in field.split("."):
                v = v.get(k) if isinstance(v, dict) else None
            if v is None:
                die(f"Catalog: model {m.get('id', '?')} has no '{field}' (the OpenRouter API changed?)")
    return models, source


def index(m, name):
    return ((m.get("benchmarks") or {}).get("artificial_analysis") or {}).get(name)


def peak_prices(m):
    """USD per token for each kind, the highest of the base price and any time-of-day override.
    None when the price is unknown (negative: variable pricing)."""
    p = m["pricing"]
    out = {}
    for kind in PRICE_KINDS:
        vals = [float(x[kind]) for x in [p] + (p.get("overrides") or []) if x.get(kind) is not None]
        out[kind] = max(vals) if vals else None
    if out["prompt"] < 0 or out["completion"] < 0:
        return None
    for kind in ("input_cache_read", "input_cache_write"):
        if out[kind] is None or out[kind] < 0:
            out[kind] = out["prompt"]  # no cache price: billed as input
    return out


def reason_filtered(m, min_ctx, today):
    """Why a model can never be a candidate, or None."""
    mid = m["id"]
    if mid.startswith("openrouter/"):
        return "OpenRouter router"
    if mid.startswith("~"):
        return "alias"
    if mid.endswith(":batch"):
        return "batch variant"
    if not {"tools", "tool_choice"} <= set(m["supported_parameters"]):
        return "no tool calling"
    if m["context_length"] < min_ctx:
        return f"context {m['context_length'] // 1000}k < {min_ctx // 1000}k"
    exp = m.get("expiration_date")
    if exp and str(exp)[:10] < (today + datetime.timedelta(days=EXPIRY_DAYS)).isoformat():
        return f"expires {str(exp)[:10]}"
    if peak_prices(m) is None:
        return "price unknown"
    return None


def floor_value(spec, rated):
    if spec.startswith("p"):
        vals = sorted(rated)
        if not vals:
            return 0.0
        return vals[min(len(vals) - 1, int(len(vals) * float(spec[1:]) / 100))]
    return float(spec)


def ledger_stats(path):
    stats = {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            ids = [x for x in (row.get("model") or "").split("+") if x]
            for mid in ids:
                s = stats.setdefault(mid, {"rows": 0, "accepted": 0, "cost": 0.0, "shared": False})
                s["rows"] += 1
                s["accepted"] += row.get("outcome") == "accepted"
                s["cost"] += float(row.get("api_cost_usd") or 0)
                s["shared"] |= len(ids) > 1
    return stats


def ledger_text(s):
    if not s:
        return "untested"
    per = f"{s['cost'] / s['accepted']:.2f}" if s["accepted"] else "-"
    return f"{s['accepted']}/{s['rows']}  {per}" + ("  shared" if s["shared"] else "")


def read_jsonc(path):
    """Parse JSONC: drop // and /* */ comments outside strings, then trailing commas."""
    text, out, i = open(path).read(), [], 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif text.startswith("/*", i):
            i = text.find("*/", i) + 2
        else:
            out.append(c)
            i += 1
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", "".join(out)))


def current_models(path):
    if not path:
        return {}
    try:
        agents = read_jsonc(path).get("agents") or {}
    except (OSError, ValueError) as e:
        print(f"Note: cannot parse {path} ({e}); current models not shown.", file=sys.stderr)
        return {}
    return {name: a["model"] for name, a in agents.items() if isinstance(a, dict) and a.get("model")}


def main():
    ledger_path, config_path = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
    mix = [float(x) for x in setting("MIX", "2000000,300000,0,50000").split(",")]
    if len(mix) != 4:
        die("MODEL_SUGGEST_MIX needs 4 numbers: cache read,input,cache write,output")
    top = int(setting("TOP", "5"))
    min_ctx = int(setting("MIN_CTX", "128000"))
    floors = {"MAIN": setting("FLOOR_MAIN", "p90"), "CHEAP": setting("FLOOR_CHEAP", "p50")}
    today = datetime.date.today()

    models, source = load_catalog()
    by_id = {m["id"]: m for m in models}
    stats = ledger_stats(ledger_path)
    current = current_models(config_path)

    usable = [m for m in models if reason_filtered(m, min_ctx, today) is None]
    paid = [m for m in usable if not m["id"].endswith(":free")]
    free = [m for m in usable if m["id"].endswith(":free")]
    cost = {m["id"]: sum(t * peak_prices(m)[k] for t, k in zip(mix, PRICE_KINDS)) for m in usable}
    rated = [index(m, "intelligence_index") for m in paid if index(m, "intelligence_index") is not None]
    by_cost = lambda m: (cost[m["id"]], m["id"])

    def fmt(v):
        return "-" if v is None else f"{v:g}"

    print(f"OpenRouter catalog {source}; {len(usable)} models pass filters")
    print("Reference task: {:g}M cache read, {:g}M input, {:g}M cache write, {:g}M output (MODEL_SUGGEST_MIX)"
          .format(*(t / 1e6 for t in mix)))
    print()

    picks, smoke = {}, []
    for tier, agents in TIERS:
        floor = floor_value(floors[tier], rated)
        ranked = sorted((m for m in paid if (index(m, "intelligence_index") or -1) >= floor), key=by_cost)
        shown = ranked[:top]
        width = max([len(m["id"]) for m in shown] + [20])
        print(f"{tier} tier ({', '.join(agents)}), intelligence_index >= {floor:g} ({floors[tier]})")
        print(f"   #  {'model':<{width}} est$/task  intel coding agentic   ctx  ledger (acc/all, $/acc)")
        for i, m in enumerate(shown, 1):
            print(f"  {i:>2}  {m['id']:<{width}} {cost[m['id']]:>9.2f}  {fmt(index(m, 'intelligence_index')):>5}"
                  f" {fmt(index(m, 'coding_index')):>6} {fmt(index(m, 'agentic_index')):>7}"
                  f" {m['context_length'] // 1000:>4}k  {ledger_text(stats.get(m['id']))}")
        for agent in agents:
            if agent not in current:
                continue
            raw = current[agent]
            mid = raw.removeprefix("openrouter/").split("#")[0]
            if not raw.startswith("openrouter/"):
                note = "not an OpenRouter model"
            elif mid not in by_id:
                note = "not in catalog (removed or renamed)"
            elif (why := reason_filtered(by_id[mid], min_ctx, today)) is not None:
                note = f"filtered: {why}"
            elif by_id[mid] in ranked:
                note = f"rank {ranked.index(by_id[mid]) + 1}, est$/task {cost[mid]:.2f}, {ledger_text(stats.get(mid))}"
            else:
                note = f"below floor (intelligence_index {fmt(index(by_id[mid], 'intelligence_index'))})"
            print(f"  current {agent}: {raw}  {note}")
        unrated = sorted((m for m in paid if index(m, "intelligence_index") is None), key=by_cost)[:UNRATED_ROWS]
        if unrated:
            print("  unrated (no index): " + ", ".join(f"{m['id']} {cost[m['id']]:.2f}" for m in unrated))
        if "explore" in agents:
            frees = sorted(free, key=lambda m: (-(index(m, "intelligence_index") or -1), m["id"]))[:FREE_ROWS]
            if frees:
                print("  free (explore only, rate-limited): "
                      + ", ".join(f"{m['id']} (intel {fmt(index(m, 'intelligence_index'))})" for m in frees))
        print()
        pick = next((m for m in shown if stats.get(m["id"], {}).get("accepted")), shown[0] if shown else None)
        for agent in agents:
            picks[agent] = pick
        smoke += [m["id"] for m in shown[:SMOKE_TOP] if m["id"] not in stats and m["id"] not in smoke]

    print("Paste into <project>/opencode.jsonc (agents.<name>.model; add #<variant> if wanted):")
    for _, agents in TIERS:
        for agent in agents:
            m = picks[agent]
            if m is None:
                print(f"  // {agent}: no candidate above the floor")
                continue
            s = stats.get(m["id"])
            note = "" if s and s["accepted"] else (" // no accepted task yet" if s else " // untested")
            print(f'  "{agent}": {{ "model": "openrouter/{m["id"]}" }},{note}')
    print()
    if smoke:
        print("Untested candidates in the top 3: smoke-test before use:")
        for mid in smoke:
            print(f"  AGENT_TEST_MODEL=openrouter/{mid} tests/run.sh --model")


if __name__ == "__main__":
    main()
