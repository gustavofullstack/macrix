#!/bin/sh
# MACRIX installer (macOS 13+, Apple Silicon): binary to ~/.local/bin, app bundle to ~/Applications.
# Usage: curl -fsSL https://raw.githubusercontent.com/gustavofullstack/macrix/main/scripts/install.sh | sh
set -eu
REL="https://github.com/gustavofullstack/macrix/releases/latest/download"
mkdir -p "$HOME/.local/bin" "$HOME/Applications" "$HOME/.config/macrix"
curl -fsSL "$REL/macrix-macos-arm64" -o "$HOME/.local/bin/macrix" && chmod +x "$HOME/.local/bin/macrix"
curl -fsSL "$REL/macrix.app.zip" -o /tmp/macrix.app.zip && ditto -x -k /tmp/macrix.app.zip "$HOME/Applications" && rm -f /tmp/macrix.app.zip
[ -s "$HOME/.config/macrix/keys" ] || { head -c 24 /dev/urandom | base64 | tr -d '/+=' | sed 's/^/mo_/' > "$HOME/.config/macrix/keys"; chmod 600 "$HOME/.config/macrix/keys"; echo "chave MCP gerada em ~/.config/macrix/keys"; }
echo "macrix $("$HOME/.local/bin/macrix" version) instalado. Servir: macrix serve --port 35730 · MCP: http://127.0.0.1:35730/mcp (Bearer = linha do arquivo keys)"
