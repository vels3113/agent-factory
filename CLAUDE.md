# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Planning documents and setup scripts for an AI-agent workflow (OpenCode + OpenRouter + Bash orchestration) that will run on the user's employer dev VM against a separate, large C++/C/flex project. This repo is **not** that project: nothing here is built or tested, and the scripts are meant to be run on the VM, not in this workspace.

- [solution.md](solution.md): the plan of record. Problem, constraints, the **decision log** (section 3), stack, agents and model tiers, background loop, Jenkins integration, monitoring, trial phases (1a/1b/1c), Phase 2, risks.
- [setup-guide.md](setup-guide.md): the step-by-step Phase 1a setup that uses the bootstrap scripts, plus corrections to the plan found while checking the docs.
- [bootstrap/](bootstrap/): numbered, run-in-order setup scripts (`01-` OpenRouter keys, `02-` task ledger, `03-` VM fact report, `04-` reserved for the OpenCode install, `05-` tool check after install).
- `secrets/` is gitignored. Don't read it or commit anything from it.

## Working on the documents

- Settled decisions in the decision log are reopened only with a reason. Keep later edits consistent with it: provider-neutral harness (OpenCode, not Claude Code; no Anthropic models by default), agents on the VM, the LLM never waits on or polls Jenkins, and deterministic scripts handle Git, CI, retries and budget.
- When a fact in `solution.md` turns out to be wrong (for example, OpenCode config details), record it under "Corrections to the plan" in `setup-guide.md` or fix it in `solution.md`. Don't let the two documents contradict each other.
- OpenCode facts in the plan were checked against **v1** docs (https://opencode.ai/docs/). v2 (`@opencode/cli`) has a different, unverified config format. Don't mix the two.
- Open questions that are still unknown (build system CMake vs. Make, Git server, VM resources) are answered by `bootstrap/03-vm-facts.sh` output. Don't assume them. VS Code runs locally and connects to the VM through Remote-SSH.

## Script conventions

The bootstrap scripts share these patterns. New scripts (for example the planned `agent-task.sh`, `agent-check.sh` and `jenkins-status.sh` described in `solution.md` section 8) should follow them:

- `#!/usr/bin/env bash` and `set -euo pipefail`. `03-vm-facts.sh` and `05-check-tools.sh` deliberately drop `-e` so one failing probe doesn't stop the report.
- Locations can be overridden with env vars: `AGENT_SECRETS_DIR` (default `~/.config/agent-secrets`) and `AGENT_WORK_DIR` (default `~/agent-work`).
- Idempotent and non-destructive: never overwrite existing state (ledger, keys) without asking.
- Secrets are entered at a prompt (`read -s`), never passed as arguments or written to the repo. Files are mode 600 in a 700 directory.
- The ledger columns in `02-init-ledger.sh` must match the "Ledger fields per task" list in `solution.md` section 9.

Syntax-check a script locally with `bash -n bootstrap/<script>.sh`.
