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

Creates `~/.agent-factory/ledger.csv` with the header row; never overwrites an existing ledger:

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
   /init Keep the Rules section of the existing AGENTS.md unchanged. Fill the Codebase map and Build and test sections. Start from ~/.agent-factory/repo-overview.txt if it exists. This is a large C++/C/flex repo: name the build output directories, the generated lexer .c files and their .l sources, how to build one target, and how to run one test. Keep the codebase map under 20 lines.
   ```

5. Review the result; fix it by hand if needed.
6. Move it back: `mv ~/<project>/main/AGENTS.md ~/<project>/instructions/AGENTS.md`.
7. Fill these placeholders in `~/<project>/opencode.jsonc`:
   - `TODO_BUILD_DIR` and the generated-file patterns: from `AGENTS.md`.
   - Model lines: commented out until models are chosen in a separate discussion; until then agents use the model picked with `/models`.

## 8. Task worktrees

One worktree and branch per task, under `worktrees/` (the background loop will automate this in `agent-task.sh`). By hand:

```bash
cd ~/<project>/main
git fetch origin
git worktree add ../worktrees/<task-id> -b agent/<task-id> origin/<base-branch>

# after review
git worktree remove ../worktrees/<task-id>
git branch -D agent/<task-id>
```

`git worktree list` shows all of them. Build directories inside a worktree are removed with it.

## OpenCode v2 documentation

- Config files and locations: https://opencode.ai/v2/docs/config/#locations
- Auto-update setting: https://opencode.ai/v2/docs/config/#updates
- OpenRouter setup: https://opencode.ai/v2/docs/providers/#gateways
- Model IDs and variants: https://opencode.ai/v2/docs/models/#variants
- Agents (model, mode, built-ins): https://opencode.ai/v2/docs/agents/#options
- Permissions: https://opencode.ai/v2/docs/permissions/#rules
- CLI automation (`opencode run`) and background service: https://opencode.ai/v2/docs/cli/#automation
- Migrating from v1: https://opencode.ai/v2/docs/migrate-v1/
