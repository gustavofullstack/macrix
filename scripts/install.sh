#!/bin/sh
# MACRIX installer (macOS 13+, Apple Silicon): binary to ~/.local/bin, app bundle to ~/Applications.
# Usage: curl -fsSL https://raw.githubusercontent.com/gustavofullstack/macrix/main/scripts/install.sh | sh
# Every download is checked against SHA256SUMS from the same release before anything is installed.
set -eu
REL="https://github.com/gustavofullstack/macrix/releases/latest/download"
umask 077
TMP="$(mktemp -d "${TMPDIR:-/tmp}/macrix-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT INT TERM
for f in SHA256SUMS macrix-macos-arm64 macrix.app.zip; do curl -fsSL "$REL/$f" -o "$TMP/$f"; done
( cd "$TMP" && shasum -a 256 -c SHA256SUMS >/dev/null ) || { echo "macrix: checksum mismatch — nothing installed" >&2; exit 1; }
mkdir -p "$HOME/.local/bin" "$HOME/Applications" "$HOME/.config/macrix"
install -m 0755 "$TMP/macrix-macos-arm64" "$HOME/.local/bin/macrix"
rm -rf "$HOME/Applications/macrix.app"
ditto -x -k "$TMP/macrix.app.zip" "$HOME/Applications"
KEYS="$HOME/.config/macrix/keys"
if [ ! -s "$KEYS" ]; then
  # created under umask 077: 0600 from the first byte, no chmod window
  head -c 24 /dev/urandom | base64 | tr -d '/+=' | sed 's/^/mo_/' > "$KEYS.tmp" && mv "$KEYS.tmp" "$KEYS"
  echo "chave MCP gerada em $KEYS"
fi
echo "macrix $("$HOME/.local/bin/macrix" version) instalado. Servir: macrix serve --port 35730 · MCP: http://127.0.0.1:35730/mcp (Bearer = linha do arquivo keys)"
