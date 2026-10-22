#!/usr/bin/env bash
# Store the OpenRouter API keys on the VM, readable only by the current user.
# Prompts for the keys so they never appear in shell history or this repo.
set -euo pipefail

secrets_dir="${AGENT_SECRETS_DIR:-$HOME/.config/agent-secrets}"
env_file="$secrets_dir/openrouter.env"

if [[ -e "$env_file" ]]; then
    read -r -p "$env_file exists. Overwrite? [y/N] " answer
    [[ "$answer" == [yY] ]] || { echo "Kept existing file."; exit 0; }
fi

read -r -s -p "OpenRouter key 'interactive' (\$4 limit): " key_interactive; echo
read -r -s -p "OpenRouter key 'background' (\$5 limit): " key_background; echo

for key in "$key_interactive" "$key_background"; do
    [[ "$key" == sk-or-* ]] || { echo "Error: keys must start with 'sk-or-'." >&2; exit 1; }
done

mkdir -p "$secrets_dir"
chmod 700 "$secrets_dir"
umask 077
cat > "$env_file" <<KEYS
OPENROUTER_KEY_INTERACTIVE=$key_interactive
OPENROUTER_KEY_BACKGROUND=$key_background
KEYS
chmod 600 "$env_file"

echo "Saved $env_file (mode 600)."
