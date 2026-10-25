# Setup Guide — Phase 1a

## 1. OpenRouter: credit and keys

1. Create an OpenRouter account; buy $10 of credit (about $9.45 usable after the fee).
2. **Disable automatic top-ups** (Settings → Credits).
3. Create two API keys with credit limits (https://openrouter.ai/settings/keys):
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
   /init Keep the Rules section of the existing AGENTS.md unchanged. Fill the Codebase map and Build and test sections. Start from ~/.agent-factory/repo-overview.txt if it exists. This is a large C++/C/flex repo: name the build output directories, the generated lexer .c files and their .l sources, how to build one target, and how to run one test. List the configure presets in CMakePresets.json with their binaryDir pattern, and the presets the Jenkinsfile builds. Keep the codebase map under 20 lines.
   ```

5. Review the result; fix it by hand if needed.
6. Move it back: `mv ~/<project>/main/AGENTS.md ~/<project>/instructions/AGENTS.md`.
7. Fill these placeholders in `~/<project>/opencode.jsonc`:
   - `TODO_BUILD_DIR`: the presets' `binaryDir` pattern from `AGENTS.md`, for example `*/build/*` for `${sourceDir}/build/${presetName}`. For Make, the build output directories it names.
   - The generated-file patterns: from `AGENTS.md`.
   - Model lines: commented out until models are chosen in a separate discussion; until then agents use the model picked with `/models`.

## 8. Task workflow

Every task gets its own worktree `worktrees/<task-id>` on branch `agent/<task-id>`, and an entry in the agent task journal. Task IDs:

- `TASK-<n>`: Taiga tasks.
- `VM-<n>`: local tasks that don't go through Taiga (bugs found during development, side tasks), numbered by `agent-task.sh new`.
- CI fixes are not new tasks; they are further attempts on the task's own branch.

One-time setup (run after step 5; the base branch is where task branches start):

```bash
bootstrap/08-task-workflow.sh ~/<project> lemon
```

- Writes `BASE_BRANCH` to `~/<project>/agent.env`; adds `.agent/` to `main/.git/info/exclude`; links `agent-task.sh` and `agent-check.sh` into `~/.local/bin`.
- Registers [scripts/agent-worktree-setup.sh](scripts/agent-worktree-setup.sh) as OpenCode's project start command. OpenCode runs it in every worktree it creates, whether you, the script or an agent asked for it. It moves the worktree from a detached HEAD to `agent/<task-id>` (from `origin/<base>`, no upstream) and rejects names that are not task IDs or unallocated `VM-<n>` IDs.
- A layout created before this step needs `"worktree": { "directory": "../worktrees" }` in `~/<project>/opencode.jsonc` (see [templates/opencode.jsonc](templates/opencode.jsonc)); the script warns if it is missing.

Then add `CHECK_PRESET=<preset>` to `~/<project>/agent.env`: the CMake preset agents check and prebuild by default (step 7 lists the presets in `AGENTS.md`).

Daily use:

```bash
agent-task.sh start TASK-1234 "Short title"        # creates the worktree, opens OpenCode in it (with a prebuild); reruns reopen it
agent-task.sh start --new "Short title" [--parent TASK-1234]   # local task: allocates VM-<n>, then starts it
agent-task.sh new "Short title" [--parent TASK-1234]           # allocate VM-<n> only (agents use this)
agent-task.sh done TASK-1234                        # after review: removes the worktree and the local branch
agent-task.sh list                                  # journal index
```

- `done` refuses when the worktree has uncommitted changes and keeps the branch if it has commits on no remote.
- `done` writes the task's row to the ledger (step 2). It asks for origin, your hands-on minutes, outcome and notes. It fills model, provider, session IDs, cost and agent minutes (prompt-to-idle time, minus time spent in `agent-check.sh`) from the OpenCode sessions that ran in the worktree, and the check rounds and failed rounds from the checks OpenCode ran. Jenkins rounds stay empty until that script exists. The cost is OpenCode's figure; the OpenRouter Activity page is authoritative. Build time and disk use are not model data, so they go to the task journal: one line per check or prebuild with its duration, and the worktree's disk use at `done`.
- Agents can start another task themselves with OpenCode's `worktree_create` and `session_move` tools (see [templates/AGENTS.md](templates/AGENTS.md)); the start command applies the same rules.

Local check (`agent-check.sh`, run inside a task worktree):

```bash
agent-check.sh [--preset <name>] [<test>...]   # incremental build, then the named tests
agent-check.sh --prebuild [--preset <name>]    # configure and build only
```

- `agent-task.sh start` runs `--prebuild` in the background while the session is open, so the agent's first check finds a warm build; it stops the prebuild when the session ends. A check of the same build waits for it.
- Agents run it as an OpenCode background command (see [templates/AGENTS.md](templates/AGENTS.md)): OpenCode 2.1.3 stops foreground shell commands after 2 minutes, a fixed default that no setting changes.
- Short output: the first 5 compiler, flex, linker or CMake errors with their context, or the failing tests with the end of their output; the full log is in `.agent/check/`. Exit codes: 0 passed, 1 build failed, 2 tests failed, 3 setup error, 4 timed out or no free build slot, 5 files changed during the check.
- No changes against `origin/<base>`: passes without building. Only Python or shell files changed: syntax check only, no build.
- Build directory: with a CMake preset, the preset's own `binaryDir`, so each worktree builds each preset separately. It is read from CMake's configure output and remembered until `CMakePresets.json` or `CMakeUserPresets.json` changes. If it isn't ignored by Git yet, it is added to `main/.git/info/exclude`. A preset whose `binaryDir` lies outside the worktree is refused (exit 3), because all tasks would share that build. CMake checks need a preset: `--preset <name>` or `CHECK_PRESET`, otherwise exit 3. Make builds in the worktree itself. Uses ccache when it is installed; builds run at low CPU and I/O priority.
- Commands come from `BUILD_SYSTEM` in `vm.env`: CMake (`cmake --preset`, `cmake --build`, `ctest -R`) or Make (`make`, tests as make targets). To change them, define `check_configure`, `check_build` and `check_test` in `~/<project>/agent.env`. These shell functions run in the worktree with `BUILD_DIR`, `PRESET`, `JOBS` and `LOAD` set; `check_test` gets the test names as arguments. They are required when `BUILD_SYSTEM` is `unknown`.
- Settings in `~/<project>/agent.env` (defaults in [scripts/agent-check.sh](scripts/agent-check.sh)):

  | Setting | Default | Meaning |
  | --- | --- | --- |
  | `CHECK_SLOTS` | 5 | checks running at once on the VM, across worktrees |
  | `CHECK_JOBS` | min(CPUs/2, RAM GB/2) | build jobs per check |
  | `CHECK_LOAD` | CPU count | no new build jobs above this load average |
  | `CHECK_PRESET` | none | CMake preset when `--preset` is not given; also used by the prebuild. Needed for CMake |
  | `CHECK_TIMEOUT_MIN` | 20 | time limit of one check, after it got its build slot |
  | `CHECK_PREBUILD_TIMEOUT_MIN` | 120 | time limit of a prebuild |
  | `CHECK_WAIT_MIN` | 60 | wait for a build slot or for another check of the same build |

- Name the presets CI checks in the Build and test section of `AGENTS.md`, so agents pick the right ones.

Journal and reports (under `~/.agent-factory/`):

- `journal/index.md`: one row per task (source Taiga/local, parent, title, status). `journal/<task-id>.md`: append-only events, written only by scripts. `journal/<task-id>.checks.tsv`: one row per `agent-check.sh` run (start, end, kind, preset, exit code, OpenCode session), read by `done` for the ledger.
- Agents write `.agent/report.md` in their worktree. When the session ends (and on `done`), the script moves it to `reports/<task-id>/<timestamp>-<label>.md` and links it from the task's journal.

## Tests

Each suite runs in a throwaway sandbox (own HOME, OpenCode data and service port), so it never touches the real setup:

```bash
tests/run.sh            # OpenCode behavior + task workflow, no model (under a minute; the first run downloads OpenCode)
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
