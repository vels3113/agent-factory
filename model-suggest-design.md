# Design: `model-suggest.sh`, model suggestions per agent

Status: built (`scripts/model-suggest.sh`, `scripts/model_suggest.py`, `tests/model-suggest.sh`). Phase 1 scope; deferred parts are listed at the end with the reason for each.

## Purpose

Suggest OpenRouter models for each OpenCode agent from the current catalog and our own results, and print ready-to-paste `agents.<name>.model` lines. Rerun it whenever the model market changes; it replaces the hand-kept candidate list in `solution.md` section 5. It only suggests: it never edits `opencode.jsonc` and never picks a model on its own.

The tool lists models from every vendor. The decision log's "no Anthropic models by default" applies to what goes into `opencode.jsonc`, which the user decides when pasting.

Out of scope: provider terms (retention, training, ZDR, privacy policies), provider or endpoint choice, per-task routing.

## Files

| File | Role |
| --- | --- |
| `scripts/model-suggest.sh` | Bash wrapper, script conventions from `CLAUDE.md`; runs the Python part with `python3 -I`. Linked into `~/.local/bin` by `08-` like the other scripts. |
| `scripts/model_suggest.py` | All logic; Python 3.10 standard library only (Ubuntu 22). |
| `tests/model-suggest.sh` | Offline test on a saved catalog fixture and a sample ledger. |

## Inputs

- **Catalog:** one `GET https://openrouter.ai/api/v1/models` call, no key. Fields used (checked against the live API on 2026-10-25): `id`, `context_length`, `supported_parameters` (`tools`, `tool_choice`), `pricing.{prompt, completion, input_cache_read, input_cache_write}` (USD per token, as strings), `pricing.overrides[]` (prices by UTC day and hour), `expiration_date`, `benchmarks.artificial_analysis.{intelligence_index, coding_index, agentic_index}` (any may be missing or null).
- **Ledger:** `~/.agent-factory/ledger.csv` (`$AGENT_FACTORY_DIR`). Columns used: `model`, `api_cost_usd`, `outcome`. OpenCode writes the model ID without the `openrouter/` prefix and joins several models with `+`.
- **Current models:** the `agents.<name>.model` lines in `~/<project>/opencode.jsonc`, commented-out lines ignored.

## Tiers

From `solution.md` section 5: **main** tier for `build` and `plan`, **cheap** tier for `explore` and `ci-fix`. One shortlist per tier; agents in a tier share it.

## Filters

A model is a candidate only if all of these hold:

- `tools` and `tool_choice` in `supported_parameters`;
- `context_length` >= `MODEL_SUGGEST_MIN_CTX`;
- no `expiration_date` within 30 days;
- not an OpenRouter router (`openrouter/*`), alias (`~*`) or batch variant (`*:batch`, asynchronous);
- not `*:free`, except as extra rows for `explore`.

Without the router, alias and batch filters, the cheapest entries in the catalog are exactly these.

## Ranking

1. **Quality floor per tier:** `intelligence_index` >= `MODEL_SUGGEST_FLOOR_MAIN` or `MODEL_SUGGEST_FLOOR_CHEAP`, either a number or a percentile of the rated paid candidates (`p90`), so the floor follows the market and survives a rescaled index. With the catalog of 2026-10-25, `p75` (33.6) put cheap models at the top of the main tier, the same as the cheap tier; `p90` (43.6) gives a distinct main tier. This index has the best coverage (233 of 354 candidates on 2026-10-25). `coding_index` (141) and `agentic_index` (107) are too sparse for a floor (current cheap candidates lack them) and are shown only.
2. **Order:** estimated cost of one reference task, ascending: the shared token mix `MODEL_SUGGEST_MIX` times the model's prices. With `overrides`, use the highest price of each kind (the weekday peak), so time-of-day discounts never make a model look cheaper than it is. A missing cache-read price counts as the full input price.
3. **Unrated:** models without `intelligence_index` are not dropped (new models often have none yet); the cheapest few go to a separate "unrated" line.

The ledger does not change the order in Phase 1: with one model per tier and 10 to 20 trial tasks, it is too small to score with. It is shown next to the estimate.

## Evidence

- **Ledger join:** per model, accepted/total tasks and cost per accepted task. A row listing several models counts for each and is marked "shared".
- **Untested:** a model with no ledger rows. For untested models in a tier's top 3, the output prints the smoke-test command: `AGENT_TEST_MODEL=openrouter/<id> tests/run.sh --model`.

## Output

```
OpenRouter catalog fetched 2026-10-25 14:02 UTC; 354 models pass filters
Reference task: 2.0M cache read, 0.3M input, 0.05M output (MODEL_SUGGEST_MIX)

MAIN tier (build, plan), intelligence_index >= 45
  #  model                 est$/task  intel coding agentic  ctx   ledger (acc/all, $/acc)
  1  <vendor>/<model>      0.41       52    48     -        256k  untested
  2  ...
  current build: <vendor>/<model>   (shown even if outside the top N)
  unrated (no index): <id> 0.22, <id> 0.30

Paste into ~/<project>/opencode.jsonc:
  "build": { "model": "openrouter/<vendor>/<model>" }, ...

Untested candidates in the top 3: smoke-test before use:
  AGENT_TEST_MODEL=openrouter/<id> tests/run.sh --model
```

**Paste block:** per tier, the best-ranked model in the shown top N with at least one accepted ledger row (so a tested main-tier model is not suggested for the cheap tier); if none has one, rank 1, marked `// untested` (no ledger rows) or `// no accepted task yet`. Format `openrouter/<vendor>/<model>`; `#<variant>` is left to the user.

**Current model:** each configured `agents.<name>.model`, as written, with its rank, estimate and ledger figures, or why it is not ranked: not in catalog (removed or renamed), filtered (with the filter), below the floor, or not an OpenRouter model.

## Settings

Env vars with defaults; no config file.

| Variable | Default | Meaning |
| --- | --- | --- |
| `MODEL_SUGGEST_MIX` | `2000000,300000,0,50000` | Reference task tokens: cache read, input, cache write, output. A guess until real token splits exist. |
| `MODEL_SUGGEST_FLOOR_MAIN` | `p90` | `intelligence_index` floor, main tier: a number, or `p<N>` for a percentile |
| `MODEL_SUGGEST_FLOOR_CHEAP` | `p50` | Floor, cheap tier |
| `MODEL_SUGGEST_TOP` | `5` | Rows per tier |
| `MODEL_SUGGEST_MIN_CTX` | `128000` | Minimum context length |
| `MODEL_SUGGEST_CATALOG` | (API) | Read the catalog from this file; used by the test |

## Errors

- API unreachable or a used field missing from the response: stop with a message naming the field (the API changed).
- No ledger: stop with a pointer to `bootstrap/02-init-ledger.sh`.
- No `opencode.jsonc`: skip the "current" lines with a pointer to `bootstrap/03-project-layout.sh`.

## Tests

`tests/model-suggest.sh`, run by `tests/run.sh`, no network: a trimmed catalog fixture and a sample ledger. Checks the filters (router, alias, batch, free, tools, context, expiry), the peak price from `overrides`, the floor and the unrated line, the ledger join including shared rows, and the paste block (accepted model chosen over a cheaper untested one; `// untested` when none is accepted).

## To verify while building

- The test sandbox has its own HOME, so `AGENT_TEST_MODEL=openrouter/...` needs the OpenRouter key inside it. Check how OpenCode v2 takes it (env variable or auth file) in the v2 docs, and pass it without writing it to the repo.
- Whether `tests/agent-model.sh` exercises a full edit-build-fix loop or only tool calls and the `AGENTS.md` rules. If only the latter, add a build-and-fix step for the smoke test.

## Deferred

| Part | Reason | Revisit when |
| --- | --- | --- |
| Endpoints API (uptime, quantization, implicit caching per provider) | Provider choice is not possible in Phase 1 (the model string does not select one; passing OpenRouter routing options through OpenCode is unverified), and OpenRouter falls back across providers | Provider routing is adopted (Phase 2) |
| Catalog cache and `--offline` | One free call per run; runs are rare | Comparing catalogs over time is needed |
| Smoke-result file and `canonical_slug` change detection (silent model updates) | Unlikely to matter over a few trial weeks | Models stay in use for months |
| Token mix per agent | Guesses without data add false precision | The ledger or OpenCode session data gives real token splits per agent |
| Ledger-weighted ranking | Too few rows | Enough tasks per model to compare |
| Per-task routing from `agent-task.sh` | `solution.md` section 11 | Phase 2 |
