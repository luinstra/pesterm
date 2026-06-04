#!/usr/bin/env bash
#
# build-app.sh — dev build script. Assembles pesterm.app from the SwiftPM release
# binary, renders Info.plist, and ad-hoc codesigns the assembled bundle.
#
# NSUserNotification posts only from a bundle with an identity, so a well-formed
# .app (with the version/package-type keys AND NSAppleEventsUsageDescription) is
# required even for dev. swift-argument-parser links statically into the binary —
# no extra payload to bundle.
#
# Run from the repo root: scripts/build-app.sh
# Output: ./pesterm.app
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP="pesterm.app"
APP_BUNDLE="$REPO_ROOT/$APP"
BIN_NAME="pesterm"
BUNDLE_ID="com.luinstra.pesterm"

echo "==> 1/4 swift build -c release"
swift build -c release

BUILT_BIN="$(swift build -c release --show-bin-path)/$BIN_NAME"
if [[ ! -x "$BUILT_BIN" ]]; then
    echo "error: built binary not found at $BUILT_BIN" >&2
    exit 1
fi

echo "==> 2/4 assemble $APP/Contents/{MacOS,Resources}"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BUILT_BIN" "$APP_BUNDLE/Contents/MacOS/$BIN_NAME"

echo "==> 3/4 render Info.plist from template"
cp "$REPO_ROOT/bundle/Info.plist.template" "$APP_BUNDLE/Contents/Info.plist"

# Sanity: NSAppleEventsUsageDescription is load-bearing for the reveal (Task 4).
# Without it, TCC SIGKILLs the process at the first ScriptingBridge call.
if ! /usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" \
        "$APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1; then
    echo "error: Info.plist missing NSAppleEventsUsageDescription" >&2
    exit 1
fi

# Codesign ordering (C4): the binary is ALREADY inside the assembled bundle; sign the
# .app as assembled, never a loose binary you then copy in.
echo "==> 4/4 ad-hoc codesign the assembled bundle"
codesign -s - --force --deep "$APP_BUNDLE"

echo
echo "Built: $APP_BUNDLE"
echo "Inner binary: $APP_BUNDLE/Contents/MacOS/$BIN_NAME"
echo "Bundle id: $BUNDLE_ID"
echo
echo "Verify signature:  codesign -dv \"$APP_BUNDLE\""
echo "Run (from iTerm2):  \"$APP_BUNDLE/Contents/MacOS/$BIN_NAME\" post --message 'test'"
