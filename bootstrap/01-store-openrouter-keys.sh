#!/usr/bin/env bash
# Store OpenRouter API keys on the VM, readable only by the current user.
# Prompts for any number of named keys so they never appear in shell history or this repo.
# Each key is written as OPENROUTER_KEY_<NAME>=... (name upper-cased, '-' becomes '_').
set -euo pipefail

secrets_dir="${AGENT_SECRETS_DIR:-$HOME/.config/agent-secrets}"
env_file="$secrets_dir/openrouter.env"

if [[ -e "$env_file" ]]; then
    read -r -p "$env_file exists. Overwrite? [y/N] " answer
    [[ "$answer" == [yY] ]] || { echo "Kept existing file."; exit 0; }
fi

lines=()
names=()
while true; do
    read -r -p "Key name (empty to finish): " name
    [[ -n "$name" ]] || break
    if [[ ! "$name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
        echo "Error: name must start with a letter and contain only letters, digits, '_' or '-'." >&2
        continue
    fi
    var="OPENROUTER_KEY_$(tr '[:lower:]-' '[:upper:]_' <<< "$name")"
    if [[ " ${names[*]-} " == *" $var "* ]]; then
        echo "Error: $var already entered." >&2
        continue
    fi
    read -r -s -p "Key '$name': " key; echo
    [[ "$key" == sk-or-* ]] || { echo "Error: keys must start with 'sk-or-'." >&2; continue; }
    names+=("$var")
    lines+=("$var=$key")
done

(( ${#lines[@]} > 0 )) || { echo "Error: no keys entered." >&2; exit 1; }

mkdir -p "$secrets_dir"
chmod 700 "$secrets_dir"
umask 077
printf '%s\n' "${lines[@]}" > "$env_file"
chmod 600 "$env_file"

echo "Saved ${#lines[@]} key(s) to $env_file (mode 600): ${names[*]}"
