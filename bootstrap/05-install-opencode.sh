#!/usr/bin/env bash
# Install a pinned OpenCode v2 with the official installer (no Node needed)
# and disable self-updates in the global config.
# Usage: 05-install-opencode.sh   (override the version with OPENCODE_VERSION)
set -euo pipefail

version="${OPENCODE_VERSION:-2.1.3}"
install_dir="$HOME/.opencode/bin"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

# v1 and v2 share the `opencode` command; don't silently replace a v1 install.
if command -v opencode >/dev/null; then
    installed="$(opencode --version 2>/dev/null | awk '{print $NF}')"
    installed="${installed#v}"
    if [[ "$installed" == 1.* ]]; then
        read -r -p "OpenCode $installed (v1) is installed at $(command -v opencode). Replace it with v2? [y/N] " answer
        [[ "$answer" == [yY] ]] || { echo "Kept v1. Nothing installed."; exit 0; }
    fi
fi

installer="$(mktemp)"
trap 'rm -f "$installer"' EXIT
curl -fsSL https://opencode.ai/v2/install -o "$installer"
bash "$installer" --version "$version"

# `update` is read from the global config only; project values are ignored.
mkdir -p "$config_dir"
config=""
for f in "$config_dir/opencode.jsonc" "$config_dir/opencode.json"; do
    [[ -e "$f" ]] && { config="$f"; break; }
done
if [[ -z "$config" ]]; then
    config="$config_dir/opencode.jsonc"
    cat > "$config" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  // Pinned by bootstrap/05-install-opencode.sh; upgrade deliberately.
  "update": "disable",
}
JSON
    echo "Created $config with \"update\": \"disable\"."
elif grep -q '"update"[[:space:]]*:[[:space:]]*"disable"' "$config"; then
    echo "$config already disables updates."
else
    echo "WARNING: $config exists; add \"update\": \"disable\" to it by hand." >&2
fi

echo
"$install_dir/opencode" --version
echo "Open a new shell (or add $install_dir to PATH) to use \`opencode\`."
