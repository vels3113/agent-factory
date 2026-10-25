# AI Agent Workflow — Solution and Implementation Plan

## 1. Problem

Split software engineering work across AI agents, keeping API costs low while maintaining acceptable productivity.

- **Work:** a large standalone C++/C/flex application with Python and Bash scripting, 1000+ files, developed on the employer's VM.
- **Two modes:**
  - **Background agents:** independently execute tasks the user owns and decides on.
  - **Interactive agents:** assist with work the user shares or presents.
- **Goals:**
  - Use a standard, maintainable, provider-neutral stack.
  - Start delivering as soon as possible; streamline communication and task management later.
  - Monitor costs and productivity from the start.
  - Gain provider flexibility and optimize costs later.
- **Out of scope:** other team members using or reviewing the agents' output.

## 2. Constraints

| Area | Constraint |
| --- | --- |
| VM | Ubuntu 22, runs 24/7, internet access, any tool can be installed. Agents run here. |
| Privacy | Source code may be sent to any LLM provider; no privacy or data-residency rules apply. |
| Code and CI | Git and Jenkins run on other internal VMs, so cloud-hosted agents are ruled out. |
| Jenkins | Multibranch pipeline that starts automatically on every branch push. A full run takes about 30 minutes; lighter checks run on the VM. |
| Models | Provider-neutral; no Anthropic models by default. |
| Budget | $10 trial top-up to compare with the previous tool; no $100+ upfront commitment. |
| Baseline | A small subscription-based provider with a proprietary model, used semi-autonomously through a VS Code extension. |
| Editor | VS Code runs locally and connects to the VM with Remote-SSH; OpenCode, clangd and extensions run on the VM. |
| Language | C++, C, flex (`.l`), Python, Bash. Build system: CMake, with several presets checked in CI; the scripts also support Make. |

## 3. Decision log

These decisions were settled in the design discussion; reopen only with a reason.

| Decision | Rationale | Rejected alternative |
| --- | --- | --- |
| Provider-neutral harness (OpenCode) | User requires provider neutrality; keeps models swappable | Vendor-specific harnesses (e.g. Claude Code) |
| OpenCode v2, pinned (2.1.3) | Current major version (stable on npm); avoids a v1-to-v2 config migration later | OpenCode v1 (the plan was first checked against v1 docs) |
| `AGENTS.md` and OpenCode config kept outside the project repo, in a parent folder named after the project | The team repo stays unchanged (other team members are out of scope); OpenCode finds project config in parent directories, so one copy serves the repo and every worktree, scoped to this project | Committing them to the project repo; global OpenCode config (applies to every project) |
| Task worktrees created through OpenCode's worktree API; a project start command (`agent-worktree-setup.sh`) sets branch `agent/<task-id>` and the journal entry | One code path for the user, scripts and agents; OpenCode tracks the worktrees and agents can `session_move` into them. OpenCode 2.1.3 creates worktrees on a detached HEAD, so branch naming lives in the hook (checked in the binary and by a test, not in the docs) | Plain `git worktree add` in scripts (agent-created worktrees would skip the rules); a TypeScript worktree-strategy plugin |
| Agent task journal separate from Taiga; IDs `TASK-<n>` (Taiga) and `VM-<n>` (local) | CI fixes and bugs found during development don't go through Taiga | Taiga as the only task source |
| Agents run on the dev VM | Git and Jenkins are internal; the VM runs 24/7 | Cloud-hosted background agents |
| Split agents by task difficulty, not by workflow | Cost savings come from model routing; workflow data does not exist yet | Workflow-specific agents from day 1 |
| OpenRouter for billing in the trial | One $10 top-up covers all providers; per-key limits | Direct provider accounts, LiteLLM gateway (deferred to Phase 2) |
| Pay per token for the trial | Small, controlled spend to compare with the subscription | Subscription plans ($100+ upfront) |
| Jenkins is the authoritative verification | Matches team CI; lighter local checks between runs | Local-only verification |
| The LLM never waits on Jenkins | Polling loops and expired prompt caches waste tokens | Agent polling CI inside its session |
| No privacy routing rules | User confirmed none apply | Provider allow-lists, zero-retention routing |
| Build-resource strategy decided by iteration | Disk, CPU and build time interact; no single upfront answer | Fixing the build layout upfront |
| Ledger records only the model's work; build time and disk use go to the task journal | The ledger compares models and tasks; build data describes the VM and guides build-resource tuning | Build time and disk columns in the ledger |
| `agent-check.sh` is a generic wrapper; the repo's CI procedure lives in a check profile (`~/<project>/agent-check.conf`, sourced bash) drafted by `09-check-profile.sh`, completed with an OpenCode prompt, validated by a build | Agent features (interface, output, limits, logs) stay the same for any repo; the profile mirrors CI, which has several presets and test runs | Build-system defaults inside the wrapper; settings in `agent.env` |
| Agents run `agent-check.sh` as an OpenCode background command | OpenCode 2.1.3 stops foreground shell commands after 2 minutes (a fixed default, found in the binary); background commands have no limit and report when done | Relying on a timeout setting (none in 2.1.3); a plugin that sets the timeout |
| Validate interactive value before scaling background | With 30-min CI and one agent, background throughput is a few tasks per day | Parallel background agents from day 1 |

## 4. Stack

OpenCode + OpenRouter + `AGENTS.md` + Bash orchestration; no other services in Phase 1.

| Layer | Choice | Notes |
| --- | --- | --- |
| Harness | [OpenCode v2](https://opencode.ai/v2/docs) | Open-source, model-agnostic terminal agent. Pinned to 2.1.3; `"update": "disable"` in the global config. A v2 VS Code integration is not verified; the integrated terminal over Remote-SSH works regardless. |
| Billing and routing | OpenRouter | One account for many providers; spend visible per key, model and provider. |
| Instructions | `AGENTS.md` | Portable across tools. Includes a short codebase map (architecture, key directories, build entry points). Permissions are enforced in tool config, not in this file. Kept outside the project repo at `~/<project>/instructions/AGENTS.md` and loaded through the [`instructions`](https://opencode.ai/v2/docs/instructions/) key in `~/<project>/opencode.jsonc`; drafted and refreshed with OpenCode `/init`. |
| Code navigation | clangd + `compile_commands.json` | Optional at first if generating the compilation database is hard. CMake: `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`; Make: `bear -- make`. |
| Orchestration | Bash scripts | Task lifecycle, Git, Jenkins polling, retries, budget checks. |
| Isolation | Git worktree + branch per background task | Layout: `~/<project>/main/` (repo), `~/<project>/worktrees/<task-id>/` (branch `agent/<task-id>`), with the OpenCode config and `AGENTS.md` in `~/<project>/`. Build-directory layout decided by iteration (section 8). |

## 5. Agents, agent classes and model tiers

Two model tiers, two credential classes; specialize further only when trial data justifies it.

**Model tiers** (candidates, not verdicts — smoke-test each in OpenCode on one edit-build-fix loop before use; cheap models may call tools unreliably):

| Tier | Used for | Candidates |
| --- | --- | --- |
| Cheap | Exploration, CI-log triage, summaries, straightforward fixes, first repair attempt | DeepSeek V4.1 Flash, GLM-5.3 Flash |
| Main | Implementation and harder repairs | GPT-6.1 Sol; budget alternative MiMo V2.6 Flash |
| Premium | None during the trial; raise reasoning effort or escalate only when task difficulty justifies it | — |

The candidates go stale quickly; the planned `model-suggest.sh` ranks current OpenRouter models per tier from the catalog and the ledger ([model-suggest-design.md](model-suggest-design.md)).

Record exact model IDs, provider, cost and outcome for every task. Judge models by cost per accepted task and human effort saved, not by token price.

**Agent classes (credentials):**

- **Restricted (default):** no push credentials. Runs as a separate Unix user so it cannot read the user's `~/.ssh`, `~/.git-credentials` or environment. The orchestrator commits and pushes. Its worktrees must sit under the project folder so it loads the same rules; the folder must be readable by that user.
- **Push-enabled:** may push only to `agent/*` branches, using a dedicated Git account or key. Enforce the branch rule with server-side branch permissions if the Git server supports them; a client-side pre-push hook is a convention, not a security boundary.

**OpenCode agents** (configured under `agents.<name>.model`, format `openrouter/<vendor>/<model>`, optional `#<variant>` for reasoning effort):

- `build` — main tier, implementation (primary).
- `plan` — main tier, planning before larger changes (primary).
- `explore` — cheap tier, read-only codebase search (subagent).
- `ci-fix` — cheap tier, first repair attempt from a Jenkins failure handoff.

## 6. Workflows

Interactive work stays semi-autonomous with approvals; background work runs through a deterministic Bash loop in which the LLM never waits on Jenkins.

### Interactive

- OpenCode in VS Code with approvals on (no `--auto`), matching the previous semi-autonomous workflow.
- Use the `plan` agent before larger changes.
- Same `AGENTS.md` and `agent-check.sh` as background agents; push only when the change would be accepted.
- The developer owns consequential actions and final acceptance.

### Background loop (`agent-task.sh "<task>"`)

1. **Pre-flight:** create a task ID; check free disk space and refuse to start below a threshold.
2. **Isolate:** create a worktree and an `agent/<task-id>` branch; pre-build the worktree before the agent starts, so the agent does not wait on a cold build.
3. **Run the agent:** `opencode run --agent build --title "<task>" "<task>"` with a defined task, scope and limits.
4. **Implement and check locally:** the agent iterates with `agent-check.sh` only, then commits and exits. It never pushes (restricted class) and never polls Jenkins.
5. **Validate and push:** the orchestrator validates the diff, then pushes — or the push-enabled agent pushes itself. Push once per finished attempt: every push starts a 30-minute Jenkins run.
6. **Wait outside the model:** the push starts the multibranch pipeline; the orchestrator polls the branch's job through the Jenkins REST API at zero token cost.
7. **Match the result to the pushed commit SHA:**
   - Green → notify the developer that the task is ready for review.
   - Red → one fresh `ci-fix` session (cheap tier) with a compact handoff: task, `git diff --stat`, previous attempts, failure excerpt.
   - No build within a timeout (branch indexing delay) → retry or escalate.
8. **Stop condition:** after one failed repair (trial) or when a limit is hit, mark the task **needs you**.

### Core rules

- Never let an LLM wait on or poll Jenkins.
- After long waits, start a fresh session with a compact handoff instead of resuming: the prompt cache has likely expired, so resuming re-bills the whole history.
- Filter logs into bounded diagnostic excerpts, keeping enough context to diagnose.
- Git operations, CI tracking, retries and budget enforcement stay in deterministic scripts.
- Limit background agents' filesystem access, commands, runtime, spend and concurrency (concurrency 1 in the trial).
- Jenkins green is not acceptance; human review is mandatory.

## 7. Jenkins integration

A branch push starts the multibranch pipeline automatically, so the orchestrator only pushes, finds the build and matches its commit SHA.

- **Trigger:** push to `agent/<task-id>`; no API trigger or credentials for job start needed.
- **Find the build:** poll the branch job's builds via the REST API and select the build whose built revision equals the pushed SHA.
- **Name encoding:** Jenkins encodes `/` in multibranch job names. Branch `agent/123` becomes job `agent%2F123`, which appears as `agent%252F123` in REST URLs.
- **Indexing delay:** a new branch may take time to appear; treat "no build within the timeout" as its own outcome (retry or escalate), not as a failure.
- **Shared capacity:** Jenkins and Git are team resources. Use the `agent/` prefix, concurrency 1, and push once per finished attempt.
- **Cleanup:** delete agent branches after review; depending on the orphaned-item settings, Jenkins then removes or disables their jobs.
- **`jenkins-status.sh` output:** build status, commit SHA, failed stage, bounded error excerpt.

## 8. Build resources and C/C++/flex specifics

Build time, CPU and disk space on the VM are an open problem: there is no known setup yet, and it will take several iterations to find one.

**Build resources (iterate):**

- Start simple: one background task at a time.
- Record build time and disk usage per task in the task journal to guide the choices (`agent-check.sh` logs each check and prebuild with its duration; `agent-task.sh done` logs disk use).
- Starting point: a build directory per worktree and preset, at most 5 checks at once (`CHECK_SLOTS`), `nice`/`ionice` (setup-guide.md steps 8 and 9).
- Options to try: reusing worktrees, shared vs. separate build directories, cleanup after each task, other `-j` and slot limits.
- Guard from day 1: the free-disk check before each task (section 6, step 1).

**C/C++/flex rules (for `AGENTS.md` and permissions):**

- Agents edit `.l` sources, never the generated lexer `.c` files; verify that lexer regeneration happens in local builds.
- Deny edits to build output and generated files.
- Validate clangd against the real compiler flags.

**Helper scripts:**

| Script | Purpose |
| --- | --- |
| `agent-task.sh` | Task lifecycle. Done (interactive): `start`/`new`/`done`/`list`, worktree via OpenCode, journal, report archive. To do (background): pre-flight, agent run, push, Jenkins polling, repair, ledger entry, limits |
| `agent-check.sh` | Done: generic wrapper around the repo's CI procedure, described in a check profile (`bootstrap/09-check-profile.sh`): presets, build, test suites, output parsers. Adds the agent interface, bounded output (first errors, failing tests), a diff filter (no build when no build file changed), prebuild while the session starts, VM-wide build slots, logs. Later, if the data warrants it: a result cache (check-result-cache.md), mapping changed files to targets and tests |
| `jenkins-status.sh` | Build status, commit SHA, failed stage, bounded error excerpt |

## 9. Cost and productivity monitoring

Phase 1 uses existing dashboards plus a lightweight ledger; no Grafana, Langfuse or similar stack.

**Tools:**

- **OpenRouter Activity page:** cost by key, model and provider; tokens and cache behavior.
- **`opencode stats`:** token usage and cost per session and model.
- **Task ledger:** CSV, one row per task written by `agent-task.sh done`: session data (model, cost, agent time without local check time) from OpenCode, local check rounds and failures from `agent-check.sh`, human minutes and outcome asked at the prompt. Jenkins rounds are added with the background loop (Phase 1b). Build time and disk use go to the task journal, not the ledger.

**Budget controls:**

| OpenRouter key | Credit limit |
| --- | --- |
| Interactive | $4 |
| Background | $5 |

Disable automatic top-ups; enforce per-task spend limits in the orchestrator.

**Ledger fields per task:** task ID, type (interactive/background, new/replayed), model and provider, session ID, API cost, agent elapsed time, human hands-on minutes, local check rounds, local check failures, Jenkins rounds, outcome (accepted / reworked / failed).

**Success measures:**

1. Cost per accepted task (compare with the subscription price divided by tasks per month).
2. Human effort per accepted task.
3. First-pass success rate and rework.

## 10. Trial plan and evaluation

The $10 trial is a feasibility and initial cost check, not a model benchmark; about $9.45 is usable after the OpenRouter fee.

| Phase | Scope |
| --- | --- |
| 1a (day 1) | Interactive only: OpenCode (pinned), OpenRouter keys, `AGENTS.md` with codebase map, clangd if practical, CSV ledger by hand |
| 1b (days 2–3) | Background loop with a restricted agent: disk guard, worktree + pre-build, local checks, orchestrator push, multibranch polling, SHA match, notify. Any red → one repair attempt → "needs you" |
| 1c (if 1b works) | Enable one push-enabled agent on `agent/*` |
| Days 4–5 | Run tasks and record ledger data |

**Task selection:**

- At least one **new** task per mode.
- Replayed tasks from the previous tool are a sanity check only: known solutions bias prompts and effort figures.
- One model per tier; no model A/B tests within $10.

**End-of-trial decision:**

- Is the workflow operationally reliable?
- Are API-based agents economical compared with the subscription?
- Do background agents save meaningful developer time?
- Which model/task pairs deserve more testing?
- What should be simplified or automated next?

## 11. Phase 2: optimization and scaling

Add agents, models and infrastructure only when trial evidence justifies them.

- **Agents:** specialize by workflow (exploration, implementation, CI repair, review); tune routing, reasoning effort, context size and caching; add stronger models selectively; automatic failure classification (code vs. infrastructure) and repair policy.
- **Concurrency:** more parallel background agents once isolation and build resources are proven.
- **Providers:** go direct to chosen providers, or self-host LiteLLM, to drop the OpenRouter fee; keep configs provider-neutral.
- **Monitoring:** a local usage dashboard if task volume makes the CSV inconvenient; a small benchmark set built from real completed tasks.
- **Communication:** streamlined task intake, notifications for completed/failed/blocked tasks, an overview of running tasks, branches, CI status and spend; automated worktree cleanup and reporting.
- **Harness:** compare a VS Code-native bring-your-own-key agent (e.g. Cline, Kilo Code) for interactive work; it is closer to the previous tool's UX.

## 12. Risks and gotchas

**Risks and gotchas:**

| Risk | Mitigation |
| --- | --- |
| Cheap models fail at tool calling in OpenCode | Smoke-test each model on one edit-build-fix loop before the trial |
| OpenCode config/behavior changes between 2.x releases | Pin the version; disable auto-update; before moving the pin, run `OPENCODE_VERSION=<new> tests/run.sh --model` |
| Long local builds outlast the prompt cache, so the next request is billed at full price | Pre-build worktrees; keep agent checks short |
| Background builds slow interactive work | `nice`/`ionice`, lower `-j`, concurrency 1 |
| Disk exhaustion from worktrees and build directories | Free-disk guard; cleanup; iterate on layout (section 8) |
| Shared Jenkins and Git load | Push once per attempt; `agent/` prefix; branch cleanup |
| Agents reading credentials as the user's Unix user | Restricted agents run as a separate user |
| Large codebase inflates token use | Codebase map in `AGENTS.md`; clangd; `explore` subagent on the cheap tier |
