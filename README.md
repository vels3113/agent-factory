# Agent Factory

A provider-neutral AI-agent workflow for a large C++/C/flex project, built on **OpenCode v2 (pinned 2.1.3) + OpenRouter + Bash orchestration**. It runs on the developer's VM, next to the internal Git and Jenkins servers. This repo holds the plan, the setup scripts and the tests. It is **not** the project the agents work on.

## The idea

Split engineering work between AI agents while keeping API cost low and productivity acceptable.

- **Interactive agents** help with work the developer is doing, with approvals on.
- **Background agents** take a defined task in their own Git worktree, iterate with the repo's build and test commands, commit, and stop.
- **Jenkins is the authority.** A push to `agent/<task-id>` starts the multibranch pipeline (about 30 min). A script polls Jenkins, not the model, so no tokens are spent waiting.
- **Money is tracked from day one.** A plugin records what OpenRouter actually charged per response, and a CSV ledger gets one row per task.

## Design

```
 developer ──► OpenCode (VS Code over Remote-SSH, or `opencode run`)
                 │  agents: build / plan (main tier), explore / ci-fix (cheap tier)
                 │  rules: ~/<project>/instructions/AGENTS.md + opencode.jsonc (outside the repo)
                 ▼
 ┌─ plugin: plugins/agent-factory ───────────────────────────────┐
 │ wraps build/test commands (env, full log, journal, checks.tsv) │
 │ records charged cost per response (costs.tsv)                  │
 │ picks the OpenRouter key per mode and agent                    │
 └────────────────────────────────────────────────────────────────┘
                 ▼
 ~/<project>/worktrees/<task-id>/   branch agent/<task-id>, made via OpenCode's worktree API
                 ▼
 agent-task.sh push ──► Jenkins ──► jenkins-status.sh (planned) ──► ledger / "needs you"
```

Main decisions (full log with rejected alternatives: [solution.md](solution.md) section 3):

| Decision | Why |
| --- | --- |
| OpenCode, no vendor harness | Models stay swappable; no Anthropic models by default |
| Config and `AGENTS.md` live in `~/<project>/`, above the repo | The team repo stays untouched; one copy serves every worktree |
| Plugin wraps the agents' own build commands | Agents ignored a custom wrapper; the plugin logs without changing the commands |
| Key per mode via the plugin | OpenCode has one active key per provider; the plugin gives background runs their own budget |
| The LLM never waits on or polls Jenkins | Waiting wastes tokens and the prompt cache expires |
| Git, CI, retries and budget are deterministic scripts | Predictable, cheap, testable |
| Two model tiers (cheap, main), restricted vs. push-enabled agents | Route by difficulty; background agents get no push credentials by default |
| Interactive value first, background later | With 30-min CI, one background agent finishes only a few tasks a day |

Success is measured as cost per accepted task, human effort per task, and first-pass success.

## Status

| Phase | State |
| --- | --- |
| 1a: interactive setup, ledger, worktree workflow, check profile, plugin, `model-suggest.sh` | Built and tested |
| 1b: background loop (disk guard, agent run, orchestrator push, Jenkins polling, one repair) | Partly built (`agent-task.sh` start/new/add/push/done/list) |
| 1c: push-enabled agent on `agent/*` | Planned |
| `jenkins-status.sh` | Planned |

## Where things are

| Path | What it is |
| --- | --- |
| [solution.md](solution.md) | The plan of record: problem, decision log, stack, agents, workflows, Jenkins, monitoring, trial, risks |
| [setup-guide.md](setup-guide.md) | Step-by-step Phase 1a setup on the VM, plus corrections to the plan |
| [bootstrap/](bootstrap/) | Numbered setup scripts, run in order: `01` keys, `02` ledger, `03` project layout, `04` VM facts, `05` OpenCode install, `06` tool check, `07` repo overview, `08` task workflow, `09` check profile |
| [scripts/](scripts/) | Day-to-day tools: `agent-task.sh` (task lifecycle), `agent-check.sh` (build and test wrapper), `agent-worktree-setup.sh` (worktree hook), `model-suggest.sh` (model shortlist), plus helpers (`agent-lib.sh`, `*.py`) |
| [plugins/agent-factory/](plugins/agent-factory/index.ts) | The OpenCode plugin (TypeScript) |
| [templates/](templates/) | `opencode.jsonc`, `AGENTS.md` and check-profile drafts installed by `03-` and `09-` |
| [tests/](tests/) | `run.sh` runs the suites in throwaway sandboxes; `--model` adds tests with a real model |
| [model-suggest-design.md](model-suggest-design.md) | Design of the model suggestion script |
| [CLAUDE.md](CLAUDE.md) | Guidance for Claude Code sessions in this repo |

## Quick start

On the VM, follow [setup-guide.md](setup-guide.md). The short version:

```bash
bootstrap/01-store-openrouter-keys.sh   # keys, entered at a prompt
bootstrap/02-init-ledger.sh
bootstrap/03-project-layout.sh <project> <repo-path-or-url>
bootstrap/04-vm-facts.sh && bootstrap/05-install-opencode.sh && bootstrap/06-check-tools.sh
bootstrap/08-task-workflow.sh ~/<project> <base-branch>   # links scripts/ into ~/.local/bin
bootstrap/09-check-profile.sh ~/<project>   # draft check profile, then --validate

agent-task.sh start --new "<title>"     # worktree, branch, prebuild, OpenCode
agent-task.sh push <id>                 # one push, one Jenkins run
agent-task.sh done <id>                 # ledger row, cleanup
```

Check the exact arguments in each script's header. The tests run anywhere (Linux, Git, Python 3):

```bash
tests/run.sh            # scripts and plugin end to end, with a stub model
tests/run.sh --model    # also with a real (free) model
```
