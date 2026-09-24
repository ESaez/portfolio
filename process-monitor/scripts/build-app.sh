#!/usr/bin/env bash
# Builds "dist/Process Monitor.app" (and a zip of it) from the Swift package.
#
#   ./scripts/build-app.sh
#   CODESIGN_IDENTITY="Apple Development: …" ./scripts/build-app.sh   # optional stable signature
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "error: Process Monitor can only be built on macOS." >&2
	exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
	echo "error: build on an Apple Silicon Mac from a native (non-Rosetta) shell." >&2
	exit 1
fi

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${CODESIGN_IDENTITY:--}"
APP="dist/Process Monitor.app"

swift build -c release --arch arm64 --product ProcessMonitor
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ProcessMonitor" "$APP/Contents/MacOS/ProcessMonitor"
sed -e "s/__VERSION__/${VERSION}/" -e "s/__BUILD__/${BUILD}/" Support/Info.plist >"$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# The app icon is drawn by a script; the app works fine without it.
ICONSET=".build/AppIcon.iconset"
rm -rf "$ICONSET"
if ! { swift scripts/make-icon.swift "$ICONSET" && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; }; then
	echo "warning: couldn't draw the app icon; continuing without it" >&2
fi

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"

rm -f dist/ProcessMonitor.zip
ditto -c -k --keepParent "$APP" dist/ProcessMonitor.zip

echo "Built $APP"
echo "Run it with: open \"$APP\""
