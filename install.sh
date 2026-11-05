#!/usr/bin/env bash
# Install ankh from this directory into ~/.local/bin. Run it from a clone you
# have read, at a release tag: ankh never downloads itself.
set -euo pipefail

src="$(dirname "$0")/ankh"
[[ -f "$src" ]] || {
  echo "install: run this from the ankh directory" >&2
  exit 1
}

BIN="${HOME}/.local/bin/ankh"
mkdir -p "$(dirname "$BIN")"
cp "$src" "$BIN"
chmod +x "$BIN"
echo "Installed ankh to $BIN"
case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*) echo "Note: add $HOME/.local/bin to your PATH" ;;
esac
