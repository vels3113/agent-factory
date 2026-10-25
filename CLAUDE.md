# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Planning documents and setup scripts for an AI-agent workflow (OpenCode + OpenRouter + Bash orchestration) that will run on the user's employer dev VM against a separate, large C++/C/flex project. This repo is **not** that project: nothing here builds or tests it, and the scripts are meant to be run on the VM. The `tests/` suites run anywhere (Linux, Git, Python 3, network for the OpenCode download), each in a throwaway sandbox.

- [solution.md](solution.md): the plan of record. Problem, constraints, the **decision log** (section 3), stack, agents and model tiers, background loop, Jenkins integration, monitoring, trial phases (1a/1b/1c), Phase 2, risks.
- [setup-guide.md](setup-guide.md): the step-by-step Phase 1a setup that uses the bootstrap scripts, plus corrections to the plan found while checking the docs.
- [check-result-cache.md](check-result-cache.md): deferred proposal for a result cache in `agent-check.sh`, with the query on `checks.tsv` that decides it.
- [bootstrap/](bootstrap/): numbered, run-in-order setup scripts (`01-` OpenRouter keys, `02-` task ledger, `03-` project layout: `~/<project>/{opencode.jsonc,instructions/AGENTS.md,main/,worktrees/}`, plus `.vscode/settings.json` with `--vscode`, `04-` VM facts to `~/.agent-factory/vm.env` (run after `03-`: paths come from the layout), `05-` OpenCode v2 install, `06-` tool check after install, `07-` optional repo overview fed to OpenCode `/init`, `08-` task workflow: base branch in `~/<project>/agent.env`, registers the worktree setup hook as OpenCode's project start command, `09-` check profile `~/<project>/agent-check.conf`: writes a CMake or Make draft whose header documents the profile interface, completed with an OpenCode prompt, `--validate` builds it in a throwaway worktree and installs it). Later scripts source `vm.env` instead of detecting facts again.
- [scripts/](scripts/): day-to-day scripts linked into `~/.local/bin` by `08-`. `agent-task.sh` (start/new/done/list tasks; `done` writes the ledger row), `agent-worktree-setup.sh` (run by OpenCode in each new worktree: branch `agent/<id>` from `origin/$BASE_BRANCH`, journal entry), `agent-check.sh` (the agents' local check: a generic wrapper that runs the check profile's presets, build and test suites, with short output, diff filter, prebuild, build slots and logs; agents run it as an OpenCode background command), `agent-lib.sh` (shared helpers). Task IDs are `TASK-<n>` (Taiga) or `VM-<n>` (local). The journal (`~/.agent-factory/journal/`) is written only by scripts; agent reports are archived under `~/.agent-factory/reports/` and linked from it.
- [tests/](tests/): `run.sh` runs `opencode-behavior.sh` (undocumented OpenCode behavior the scripts rely on: worktree API, start command, config lookup) and `task-workflow.sh` (the scripts end to end, no model); `run.sh --model` adds `agent-model.sh` (worktree tools, `AGENTS.md` rules, ledger from real sessions; free model by default). Each suite gets its own HOME and OpenCode service port; `KEEP=1` keeps the sandbox.
- [templates/](templates/): `opencode.jsonc` (agents, permissions) and `AGENTS.md` for the project repo, installed by `03-project-layout.sh` into the project folder above the repo, never committed to it. Model choice is deferred to a separate discussion, so the model lines stay commented out until the user picks models.
- `secrets/` is gitignored. Don't read it or commit anything from it.

## Working on the documents

- Settled decisions in the decision log are reopened only with a reason. Keep later edits consistent with it: provider-neutral harness (OpenCode, not Claude Code; no Anthropic models by default), agents on the VM, the LLM never waits on or polls Jenkins, and deterministic scripts handle Git, CI, retries and budget.
- When a fact in `solution.md` turns out to be wrong (for example, OpenCode config details), record it under "Corrections to the plan" in `setup-guide.md` or fix it in `solution.md`. Don't let the two documents contradict each other.
- OpenCode is **v2**, pinned to 2.1.3 (docs: https://opencode.ai/v2/docs, not the v1 docs at `/docs/`). v1 and v2 differ in config keys (`agents`, `update`, permission rules), so don't use v1 examples. `setup-guide.md` links to the relevant v2 doc sections; link to the official docs instead of restating their content.
- Open questions that are still unknown (build system CMake vs. Make, Git server, VM resources) are answered by `vm.env` from `bootstrap/04-vm-facts.sh`. Don't assume them. VS Code runs locally and connects to the VM through Remote-SSH.

## Facts about the VM and the project

These sessions have no access to the VM or the project repo. **Don't ask the user for setup information** (build system, build or test commands, paths, tool versions, VM resources, command output). Instead, write what runs on the VM and finds or uses that information:

- a script: a bootstrap probe like `04-vm-facts.sh` that writes `vm.env`, or detection at run time;
- instructions in a guide, with commands to run and what to check in their output;
- a prompt for OpenCode on the VM, like the `/init` prompt in `setup-guide.md` step 7.

Scripts read open values from `vm.env` or `~/<project>/agent.env`, or take them as settings with defaults. If a value is missing, they stop with a message that names the step that provides it. Design for every possible answer, for example both CMake and Make, rather than waiting for one.

## Script conventions

The bootstrap scripts share these patterns. New scripts (for example the planned `jenkins-status.sh` described in `solution.md` section 8) should follow them:

- `#!/usr/bin/env bash` and `set -euo pipefail`. `04-vm-facts.sh` and `06-check-tools.sh` deliberately drop `-e` so one failing probe doesn't stop the report.
- Locations can be overridden with env vars: `AGENT_SECRETS_DIR` (default `~/.config/agent-secrets`) and `AGENT_FACTORY_DIR` (default `~/.agent-factory`).
- Idempotent and non-destructive: never overwrite existing state (ledger, keys) without asking.
- Secrets are entered at a prompt (`read -s`), never passed as arguments or written to the repo. Files are mode 600 in a 700 directory.
- The ledger columns in `02-init-ledger.sh` must match the "Ledger fields per task" list in `solution.md` section 9.

Syntax-check a script locally with `bash -n bootstrap/<script>.sh`. After changing `scripts/`, `bootstrap/08-` or the templates, run `tests/run.sh`; after changing agent rules, also `tests/run.sh --model`. When a test finds new OpenCode behavior the scripts depend on, add a check to `tests/opencode-behavior.sh`.
