#!/bin/sh
# Wraps the CLI binary in a minimal .app so LaunchServices (open -a) is the
# launcher: TCC then attributes Microphone/Speech requests to macrix itself
# and shows the permission dialog once. Usage: scripts/bundle-app.sh [debug|release]
set -eu
cfg=${1:-release}
root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/.build/macrix.app"
rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
cp "$root/.build/$cfg/macrix" "$app/Contents/MacOS/macrix"
sed 's#</dict>#  <key>CFBundleExecutable</key><string>macrix</string>\n  <key>CFBundlePackageType</key><string>APPL</string>\n  <key>LSUIElement</key><true/>\n</dict>#' \
  "$root/Sources/macrix/Info.plist" > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "$app"
