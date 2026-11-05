#!/usr/bin/env bash
# Install ankh from a URL or from this directory, into ~/.local/bin.
# Usage: bash install.sh [<url-of-the-ankh-script>]
set -euo pipefail

BIN="${HOME}/.local/bin/ankh"
mkdir -p "$(dirname "$BIN")"

if [[ -n "${1:-}" ]]; then
  curl -fsSL "$1" -o "$BIN"
elif [[ -f "$(dirname "$0")/ankh" ]]; then
  cp "$(dirname "$0")/ankh" "$BIN"
else
  echo "install: give a URL, or run this from the ankh directory" >&2
  exit 1
fi

chmod +x "$BIN"
echo "Installed ankh to $BIN"
case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*) echo "Note: add $HOME/.local/bin to your PATH" ;;
esac
