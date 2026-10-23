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

## 3. VM fact check (answers the open questions)

Reports build system, Git server, CPU/RAM and disk; saves to `~/.agent-factory/vm-facts.txt`:

```bash
bootstrap/03-vm-facts.sh /path/to/project-repo
```

VS Code runs locally and connects to the VM with Remote-SSH. OpenCode, clangd and the VS Code extensions therefore run on the VM: install extensions into the "SSH: <host>" side.

Override locations with `AGENT_SECRETS_DIR` and `AGENT_FACTORY_DIR`.

## 4. Install OpenCode v2

OpenCode **v2**, pinned to **2.1.3** (the stable `latest` on npm). Docs: https://opencode.ai/v2/docs (not the v1 docs at `/docs/`).

```bash
bootstrap/04-install-opencode.sh
```

- Uses the official v2 installer (`https://opencode.ai/v2/install --version 2.1.3`). Installs to `~/.opencode/bin` and adds it to your shell's PATH.
- Asks before replacing an existing v1 install: v1 and v2 share the `opencode` command.
- Creates `~/.config/opencode/opencode.jsonc` with `"update": "disable"`. This key works only in the global config. If a global config already exists, the script warns instead of editing it.
- Another version: `OPENCODE_VERSION=2.x.y bootstrap/04-install-opencode.sh`, or `opencode upgrade 2.x.y --method curl`.

Then connect OpenRouter with a selected key: run `opencode`, type `/connect`, choose OpenRouter, paste the key. Check with `opencode auth list`.

## 5. Tool check

Run after OpenCode is installed. Checks `opencode`, `git`, `clangd`, `ccache`, and the build tool; checks `bear` only for Make builds (CMake exports `compile_commands.json` itself). Exits non-zero if anything is missing:

```bash
bootstrap/05-check-tools.sh /path/to/project-repo
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
