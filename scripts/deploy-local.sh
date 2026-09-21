#!/bin/sh
# Deploy the release binary to the launchd service WITHOUT killing it mid-flight.
# swift build rewrites .build/release/macrix in place; if launchd runs that file,
# macOS kills the process (CODESIGNING · Launch Constraint Violation). So the
# service runs a COPY at ~/.local/bin/macrix-server, replaced by rename (new inode),
# then restarted exactly once.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" && swift build -c release 2>&1 | grep -E "error|Build complete"
TARGET="$HOME/.local/bin/macrix-server"
cp "$ROOT/.build/release/macrix" "$TARGET.new" && chmod 755 "$TARGET.new" && mv -f "$TARGET.new" "$TARGET"
launchctl kickstart -k "gui/$(id -u)/com.sug.macrix"
for i in 1 2 3 4 5 6 7 8 9 10; do sleep 1; curl -s -m 2 http://127.0.0.1:35730/health && { echo; exit 0; }; done
echo "macrix: service did not answer in 10s" >&2; exit 1
