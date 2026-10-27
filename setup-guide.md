# Setup Guide — Phase 1a

## 1. OpenRouter: credit and keys

1. Create an OpenRouter account; buy $10 of credit (about $9.45 usable after the fee).
2. **Disable automatic top-ups** (Settings → Credits).
3. Create API keys with credit limits (https://openrouter.ai/settings/keys)
4. Store the keys on the VM (prompts for a name and a key, repeatedly, until you enter an empty name; writes `OPENROUTER_KEY_<NAME>` lines to `~/.config/agent-secrets/openrouter.env`, mode 600):

   ```bash
   bootstrap/01-store-openrouter-keys.sh
   ```

## 2. Task ledger

Creates `~/.agent-factory/ledger.csv` with the header row; never overwrites an existing ledger. Rows are written by `agent-task.sh done` (step 8):

```bash
bootstrap/02-init-ledger.sh
```

- `mode`: interactive / background
- `origin`: new / replayed
- `outcome`: accepted / reworked / failed

## 3. Project layout

`AGENTS.md` and the OpenCode config stay outside the repo (not committed, not in `.gitignore`). They live in a parent folder named after the project, above the repo and all task worktrees. OpenCode searches for project config from the current directory up to the filesystem root (https://opencode.ai/v2/docs/config/#locations), so every checkout under the parent loads it:

```text
~/<project>/
├── .vscode/settings.json     with --vscode: Source Control finds main/ and worktrees/*
├── opencode.jsonc            agents, permissions, "instructions" → instructions/AGENTS.md
├── instructions/AGENTS.md    outside the upward AGENTS.md search, so it loads exactly once
├── main/                     the repo
└── worktrees/<task-id>/      one worktree per task, branch agent/<task-id>
```

```bash
bootstrap/03-project-layout.sh --vscode <project> /path/to/project-repo   # or a Git URL to clone
```

- Asks before moving an existing clone to `~/<project>/main` (then runs `git worktree repair`). Reopen VS Code and terminals at the new path.
- Creates `instructions/AGENTS.md` from [templates/AGENTS.md](templates/AGENTS.md) (step 7 fills it), and `opencode.jsonc` from [templates/opencode.jsonc](templates/opencode.jsonc) with the absolute `instructions` path (https://opencode.ai/v2/docs/instructions/). Never overwrites either file.
- `--vscode`: creates `~/<project>/.vscode/settings.json` with `git.repositoryScanMaxDepth: 2`, so VS Code opened on `~/<project>` shows `main/` and every worktree in Source Control. Run it again with `--vscode <project>` (no repo argument) to add this to an existing layout.
- Parent folder location: `AGENT_PROJECTS_DIR` (default `~`).

## 4. VM fact check

Prints a report (build system, Git server, CPU/RAM, disk) and saves the values to `~/.agent-factory/vm.env` (`PROJECT_REPO`, `PROJECT_DIR`, `WORKTREES_DIR`, `BUILD_SYSTEM`, `GIT_REMOTE_URL`, `GIT_HOST`, `CPU_COUNT`, `DISK_FREE_GB`, …) for later scripts to source. Takes the project folder from step 3 (the repo is its `main/`); rerun it when the VM or repo changes:

```bash
bootstrap/04-vm-facts.sh ~/<project>
```

VS Code runs locally and connects to the VM with Remote-SSH. OpenCode, clangd and the VS Code extensions therefore run on the VM: install extensions into the "SSH: <host>" side.

Override locations with `AGENT_SECRETS_DIR` and `AGENT_FACTORY_DIR`.

## 5. Install OpenCode v2

OpenCode **v2**, pinned to **2.1.3** (the stable `latest` on npm). Docs: https://opencode.ai/v2/docs (not the v1 docs at `/docs/`).

```bash
bootstrap/05-install-opencode.sh
```

- Uses the official v2 installer (`https://opencode.ai/v2/install --version 2.1.3`). Installs to `~/.opencode/bin` and adds it to your shell's PATH.
- Asks before replacing an existing v1 install: v1 and v2 share the `opencode` command.
- Creates `~/.config/opencode/opencode.jsonc` with `"update": "disable"`. This key works only in the global config. If a global config already exists, the script warns instead of editing it.
- Another version: `OPENCODE_VERSION=2.x.y bootstrap/05-install-opencode.sh`, or `opencode upgrade 2.x.y --method curl`.

Then connect OpenRouter with a selected key: run `opencode`, type `/connect`, choose OpenRouter, paste the key. Check with `opencode auth list`.

## 6. Tool check

Run after OpenCode is installed. Checks `opencode`, `git`, `clangd`, and the build tool; checks `bear` only for Make builds (CMake exports `compile_commands.json` itself). Takes the repo path and build system from `vm.env` (step 4); a project folder argument overrides it. Exits non-zero if anything is missing:

```bash
bootstrap/06-check-tools.sh
```

## 7. Fill `AGENTS.md` with `/init`

OpenCode's built-in `/init` ("guided AGENTS.md setup"; not yet in the v2 docs) reads the README, build and CI files and representative code, then creates `AGENTS.md`, or improves an existing one in place, keeping verified guidance. Text after `/init` is passed to it as focus and constraints. It works on `AGENTS.md` in the repo root, so the file goes in for the run and back out afterwards. The same steps refresh it after layout changes.

1. Copy it into the repo: `cp ~/<project>/instructions/AGENTS.md ~/<project>/main/`. `/init` keeps its Rules section and fills the TODO sections.
2. Optional starting map, saves exploration on a large repo (read-only; writes `~/.agent-factory/repo-overview.txt`):

   ```bash
   bootstrap/07-repo-overview.sh ~/<project>
   ```

3. Pick a model: run `opencode` in `~/<project>/main`, then `/models`.
   - **Free:** OpenCode's own free models. They need an OpenCode Console sign-in (`/connect` → OpenCode). Terms differ per model; GLM-5.3-Flash Free and DeepSeek V4.1 Flash Free are zero-retention and not used for training. See https://opencode.ai/v2/docs/console/models and https://opencode.ai/v2/docs/models/#free-models.
   - **Any other:** any OpenRouter model through the key connected in step 5.
4. Run, as one line:

   ```text
   /init Keep the Rules section of the existing AGENTS.md unchanged. Fill the Codebase map and Build and test sections. Start from ~/.agent-factory/repo-overview.txt if it exists. This is a large C++/C/flex repo: name the build output directories, the generated lexer .c files and their .l sources, and the main build and test commands CI runs. Agents build and test only through agent-check.sh, so describe those commands as what agent-check.sh runs, not as commands for agents. List the configure presets in CMakePresets.json with their binaryDir pattern. Keep the codebase map under 20 lines.
   ```

5. Review the result; fix it by hand if needed.
6. Move it back: `mv ~/<project>/main/AGENTS.md ~/<project>/instructions/AGENTS.md`.
7. Fill these placeholders in `~/<project>/opencode.jsonc`:
   - `TODO_BUILD_DIR`: the presets' `binaryDir` pattern from `AGENTS.md`, for example `*/build/*` for `${sourceDir}/build/${presetName}`. For Make, the build output directories it names.
   - The generated-file patterns: from `AGENTS.md`.
   - `TODO_BUILD_COMMAND`, `TODO_TEST_COMMAND`: the commands that build and run tests, from `AGENTS.md`, one deny rule each, more rules for more commands. Agents then get these refused instead of reaching your approval prompt, and use `agent-check.sh`. For example, for CMake: `cmake --build *` and `ctest *`.
   - Model lines: commented out until models are chosen (step 10); until then agents use the model picked with `/models`.

## 8. Task workflow

Every task gets its own worktree `worktrees/<task-id>` on branch `agent/<task-id>`, and an entry in the agent task journal. Task IDs:

- `TASK-<n>`: Taiga tasks.
- `VM-<n>`: local tasks that don't go through Taiga (bugs found during development, side tasks), numbered by `agent-task.sh new`.
- CI fixes are not new tasks; they are further attempts on the task's own branch.

One-time setup (run after step 5; the base branch is where task branches start):

```bash
bootstrap/08-task-workflow.sh ~/<project> lemon
```

- Writes `BASE_BRANCH` to `~/<project>/agent.env`; adds `.agent/` to `main/.git/info/exclude`; links `agent-task.sh`, `agent-check.sh` and `model-suggest.sh` (step 10) into `~/.local/bin`.
- Registers [scripts/agent-worktree-setup.sh](scripts/agent-worktree-setup.sh) as OpenCode's project start command. OpenCode runs it in every worktree it creates, whether you, the script or an agent asked for it. It moves the worktree from a detached HEAD to `agent/<task-id>` (from `origin/<base>`, no upstream) and rejects names that are not task IDs or unallocated `VM-<n>` IDs.
- A layout created before this step needs `"worktree": { "directory": "../worktrees" }` in `~/<project>/opencode.jsonc` (see [templates/opencode.jsonc](templates/opencode.jsonc)); the script warns if it is missing.

Then set up the check profile (step 9).

Daily use:

```bash
agent-task.sh start TASK-1234 "Short title"        # creates the worktree, opens OpenCode in it (with a prebuild); reruns reopen it
agent-task.sh start --new "Short title" [--parent TASK-1234]   # local task: allocates VM-<n>, then starts it
agent-task.sh new "Short title" [--parent TASK-1234]           # allocate VM-<n> only (agents use this)
agent-task.sh done TASK-1234                        # after review: removes the worktree and the local branch
agent-task.sh list                                  # journal index
```

- `done` refuses when the worktree has uncommitted changes and keeps the branch if it has commits on no remote.
- `done` writes the task's row to the ledger (step 2). It asks for origin, your hands-on minutes, outcome and notes. It fills model, provider, session IDs, cost and agent minutes from the OpenCode sessions that ran in the worktree, and the check rounds and failed rounds from the checks OpenCode ran. Jenkins rounds stay empty until that script exists. Agent minutes are the model's working time: from each prompt, or each wake-up when a background command finishes, to idle, minus the time inside tool calls. In OpenCode 2.1.3 a tool call's time includes the wait at its approval prompt, so your approval waits and the commands' run times are not counted. The cost is OpenCode's figure; the OpenRouter Activity page is authoritative. Build time and disk use are not model data, so they go to the task journal: one line per check or prebuild with its duration, and the worktree's disk use at `done`.
- Agents can start another task themselves with OpenCode's `worktree_create` and `session_move` tools (see [templates/AGENTS.md](templates/AGENTS.md)); the start command applies the same rules.

Local check (`agent-check.sh`, run inside a task worktree; what it runs comes from the check profile, step 9):

```bash
agent-check.sh [--preset <name>]... [--suite <name>] [<test>...]   # build the presets, run the named tests
agent-check.sh --prebuild [--preset <name>]                        # configure and build only
agent-check.sh --list                                              # presets, test suites, tests
```

- `agent-task.sh start` runs `--prebuild` for the default preset in the background while the session is open, so the agent's first check finds a warm build; it stops the prebuild when the session ends. A check of the same preset waits for it.
- Agents run it as an OpenCode background command (see [templates/AGENTS.md](templates/AGENTS.md)): OpenCode 2.1.3 stops foreground shell commands after 2 minutes, a fixed default that no setting changes.
- Short output: the first 5 compiler, flex, linker or CMake errors with their context, or the failing tests with the end of their output; the full log is in `.agent/check/`. Exit codes: 0 passed, 1 build failed, 2 tests failed, 3 setup error, 4 timed out or no free build slot, 5 files changed during the check.
- Diff filter: no changes against `origin/<base>` passes without building. Changed Python and shell files get a syntax check; the build runs only if a changed file matches the profile's `CHECK_BUILD_PATHS`. Several `--preset` options build one preset after the other and stop at the first failure.
- Builds run at low CPU and I/O priority, in at most `CHECK_SLOTS` checks at once on the VM.

Journal and reports (under `~/.agent-factory/`):

- `journal/index.md`: one row per task (source Taiga/local, parent, title, status). `journal/<task-id>.md`: append-only events, written only by scripts. `journal/<task-id>.checks.tsv`: one row per `agent-check.sh` run (start, end, kind, presets, exit code, OpenCode session, tree hash of the checked files), read by `done` for the ledger.
- Agents write `.agent/report.md` in their worktree. When the session ends (and on `done`), the script moves it to `reports/<task-id>/<timestamp>-<label>.md` and links it from the task's journal.

## 9. Check profile

`agent-check.sh` is a generic wrapper; the profile `~/<project>/agent-check.conf` describes this repo's CI procedure in its terms: the presets CI builds, how to configure and build one, the test suites and how to run named tests, an output parser per step, and the files whose change needs a build. It is sourced bash; its header describes the interface. Agents may not edit it.

1. Draft it (run after step 8):

   ```bash
   bootstrap/09-check-profile.sh ~/<project>
   ```

   Writes `~/<project>/main/agent-check.draft.conf` (kept out of Git): a new CMake or Make profile for `BUILD_SYSTEM`, with the configure presets that the Jenkinsfile builds; or a copy of the installed profile, to change it later. Never overwrites a draft.
2. Complete it with OpenCode, as in step 7: run `opencode` in `~/<project>/main`, pick a model with `/models`, and send the prompt the script prints. It reads the Jenkinsfile and the scripts it calls, writes one `test_<suite>` function per CI test run, and lists what CI runs that the profile leaves out. Review the draft.
3. Validate and install it:

   ```bash
   bootstrap/09-check-profile.sh ~/<project> --validate [<preset>...]
   ```

   Builds the presets (default: the default preset) with `agent-check.sh --prebuild` in a throwaway local task worktree, checks that the build output stays out of Git, shows `agent-check.sh --list` and the step times, then moves the draft to `~/<project>/agent-check.conf` (asks before replacing a different one). The worktree is removed; its logs stay in `~/.agent-factory/reports/<task-id>/`. A cold build can take long.

Wrapper settings, overridable in the profile (defaults in [scripts/agent-check.sh](scripts/agent-check.sh)):

| Setting | Default | Meaning |
| --- | --- | --- |
| `CHECK_SLOTS` | 5 | checks running at once on the VM, across worktrees |
| `CHECK_JOBS` | min(CPUs/2, RAM GB/2) | build jobs per check |
| `CHECK_LOAD` | CPU count | no new build jobs above this load average |
| `CHECK_TIMEOUT_MIN` | 20 | time limit of one check, after it got its build slot |
| `CHECK_PREBUILD_TIMEOUT_MIN` | 120 | time limit of a prebuild |
| `CHECK_WAIT_MIN` | 60 | wait for a build slot or for another check of the same preset |

- Build directory: the one the profile's `build_dir` reports (CMake template: the preset's own `binaryDir`, read from CMake's configure output; Make template: the worktree itself). It must lie inside the worktree, or the check stops with exit 3, because tasks would share one build. If Git doesn't ignore it yet, it is added to `main/.git/info/exclude`.
- A new CMake profile adds ccache as compiler launcher when ccache is installed; a new Make profile puts its compiler symlinks first on `PATH`. If the build files already use ccache, the OpenCode prompt removes these lines.
- A proposal for a result cache, deferred until `checks.tsv` shows repeated checks of the same files: [check-result-cache.md](check-result-cache.md).

## 10. Model suggestions

`model-suggest.sh` ranks OpenRouter models per tier (main: `build`, `plan`; cheap: `explore`, `ci-fix`) from the OpenRouter catalog and the ledger, and prints `agents.<name>.model` lines to paste into `~/<project>/opencode.jsonc`. It never edits the config. Rerun it when choosing models, when the model market changes, and as ledger rows come in. Design and reasons: [model-suggest-design.md](model-suggest-design.md).

```bash
model-suggest.sh
```

- Needs the ledger (step 2) and internet access; reads the current model lines from the project config through `vm.env` (step 4). No API key: the catalog is public.
- Filters: tool calling, context of at least 128k, no expiry within 30 days; no OpenRouter routers, aliases or batch variants; free models only as extra rows for `explore`. Provider terms (retention, training) are not checked.
- Ranking: models above the tier's `intelligence_index` floor (default: top 10% of rated models for main, top half for cheap), cheapest first by the estimated cost of a reference task at peak prices. Models without an index are listed on a separate "unrated" line.
- Ledger column: accepted/all tasks and cost per accepted task for each model; "untested" when the ledger has no row for it. The paste block takes the best-ranked model with an accepted task, otherwise rank 1 marked `// untested` or `// no accepted task yet`.
- "current <agent>" lines show each configured model's rank, or why it is not ranked (not in the catalog, filtered, below the floor).
- Settings (env vars, defaults in the header of [scripts/model-suggest.sh](scripts/model-suggest.sh)): `MODEL_SUGGEST_MIX` (reference task tokens), `MODEL_SUGGEST_FLOOR_MAIN` / `MODEL_SUGGEST_FLOOR_CHEAP` (a number or `p<N>`), `MODEL_SUGGEST_TOP`, `MODEL_SUGGEST_MIN_CTX`. For example, a lower main floor: `MODEL_SUGGEST_FLOOR_MAIN=p75 model-suggest.sh`.

Using a suggestion:

1. Smoke-test an untested model before you put it in the config. The printed `AGENT_TEST_MODEL=openrouter/<id> tests/run.sh --model` does not work yet for OpenRouter models, because the test sandbox has no OpenRouter key. Until it does, try the model by hand on one small task: `/models` in `opencode`, then one edit, `agent-check.sh` and fix round.
2. Paste the lines into the `agents` section of `~/<project>/opencode.jsonc`, replacing the commented-out model lines; add `#<variant>` for a reasoning effort (https://opencode.ai/v2/docs/models/#variants). Anthropic models appear in the list; the plan excludes them by default (solution.md section 3).
3. Check that the "current" lines now show the chosen models: `model-suggest.sh | grep current`.

## Tests

Each suite runs in a throwaway sandbox (own HOME, OpenCode data and service port), so it never touches the real setup:

```bash
tests/run.sh            # OpenCode behavior + task workflow + model suggestions, no model (under a minute; the first run downloads OpenCode)
tests/run.sh --model    # also agent behavior with a free model (AGENT_TEST_MODEL to change it)
OPENCODE_VERSION=2.x.y tests/run.sh --model   # before moving the pinned version
```

## OpenCode v2 documentation

- Config files and locations: https://opencode.ai/v2/docs/config/#locations
- Auto-update setting: https://opencode.ai/v2/docs/config/#updates
- OpenRouter setup: https://opencode.ai/v2/docs/providers/#gateways
- Model IDs and variants: https://opencode.ai/v2/docs/models/#variants
- Agents (model, mode, built-ins): https://opencode.ai/v2/docs/agents/#options
- Permissions: https://opencode.ai/v2/docs/permissions/#rules
- CLI automation (`opencode run`) and background service: https://opencode.ai/v2/docs/cli/#automation
- Migrating from v1: https://opencode.ai/v2/docs/migrate-v1/
