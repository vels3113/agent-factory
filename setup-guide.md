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

Creates `~/agent-work/ledger.csv` with the header row; never overwrites an existing ledger:

```bash
bootstrap/02-init-ledger.sh
```

- `mode`: interactive / background
- `origin`: new / replayed
- `outcome`: accepted / reworked / failed

## 3. VM fact check (answers the open questions)

Reports build system, Git server, CPU/RAM and disk; saves to `~/agent-work/vm-facts.txt`:

```bash
bootstrap/03-vm-facts.sh /path/to/project-repo
```

VS Code runs locally and connects to the VM with Remote-SSH. OpenCode, clangd and the VS Code extensions therefore run on the VM: install extensions into the "SSH: <host>" side.

Override locations with `AGENT_SECRETS_DIR` and `AGENT_WORK_DIR`.

## 4. DECISION: OpenCode v1 or v2

OpenCode v2 is now published alongside v1. The two install as different packages but share the `opencode` command, so only one can be installed under the default command.

| | v1 | v2 |
| --- | --- | --- |
| npm package | `opencode-ai` | `@opencode/cli` |
| Docs | https://opencode.ai/docs/ | https://opencode.ai/v2/docs |
| Plan's facts (agents with `model`, `opencode run` flags, OpenRouter setup) | Verified against these docs | Not verified; config format may differ |
| Status | Mature | Release status unclear (the AUR package is named `opencode-beta`) |

**Recommendation: v1, latest 1.x, pinned.** Everything in the plan was checked against v1, and Phase 1 favors stability over new features. Revisit v2 in Phase 2.

## 5. Install OpenCode

Pending the decision in step 4 (`bootstrap/04-` is reserved for the install script).

## 6. Tool check

Run after OpenCode is installed. Checks `opencode`, `git`, `clangd`, `ccache`, and the build tool; checks `bear` only for Make builds (CMake exports `compile_commands.json` itself). Exits non-zero if anything is missing:

```bash
bootstrap/05-check-tools.sh /path/to/project-repo
```

## Corrections to the plan

- Disabling auto-update: the documented setting is `"autoupdate": false` in `opencode.json`. Use it in addition to (or instead of) `OPENCODE_DISABLE_AUTOUPDATE`.
- OpenRouter in OpenCode: connect it with `/connect` in the TUI (search "OpenRouter", paste the key). Model IDs have the form `openrouter/<vendor>/<model>`.
