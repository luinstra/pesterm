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
#
# REUSE: install.sh sources this file to call pesterm_assemble_bundle / pesterm_sign /
# pesterm_verify_sign. When sourced (BASH_SOURCE != $0) the standalone build at the
# bottom does NOT run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

BIN_NAME="pesterm"
BUNDLE_ID="com.luinstra.pesterm"

# Build the release binary and echo its absolute path on stdout.
pesterm_build_release() {
    swift build -c release >&2
    local built
    built="$(swift build -c release --show-bin-path)/$BIN_NAME"
    if [[ ! -x "$built" ]]; then
        echo "error: built binary not found at $built" >&2
        return 1
    fi
    echo "$built"
}

# Assemble (and render Info.plist) a .app bundle at $1 from the built binary $2.
# Does NOT sign — sign LAST, after all mutation and final placement (R3 / C4).
pesterm_assemble_bundle() {
    local app_bundle="$1"
    local built_bin="$2"

    rm -rf "$app_bundle"
    mkdir -p "$app_bundle/Contents/MacOS"
    mkdir -p "$app_bundle/Contents/Resources"
    cp "$built_bin" "$app_bundle/Contents/MacOS/$BIN_NAME"

    cp "$REPO_ROOT/bundle/Info.plist.template" "$app_bundle/Contents/Info.plist"

    # Sanity: NSAppleEventsUsageDescription is load-bearing for the reveal.
    # Without it, TCC SIGKILLs the process at the first ScriptingBridge call.
    if ! /usr/libexec/PlistBuddy -c "Print :NSAppleEventsUsageDescription" \
            "$app_bundle/Contents/Info.plist" >/dev/null 2>&1; then
        echo "error: Info.plist missing NSAppleEventsUsageDescription" >&2
        return 1
    fi
}

# Ad-hoc codesign the assembled bundle at $1. Call ONLY after all mutation + final
# placement (R3): mutating an ad-hoc-signed bundle breaks its signature.
pesterm_sign() {
    local app_bundle="$1"
    codesign -s - --force --deep "$app_bundle"
}

# Verify the signature of the bundle at $1; non-zero on a broken signature (R3).
pesterm_verify_sign() {
    local app_bundle="$1"
    codesign --verify --deep --strict "$app_bundle"
}

# Standalone dev build (only when executed directly, not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cd "$REPO_ROOT"
    APP_BUNDLE="$REPO_ROOT/pesterm.app"

    echo "==> 1/4 swift build -c release"
    BUILT_BIN="$(pesterm_build_release)"

    echo "==> 2/4 assemble pesterm.app/Contents/{MacOS,Resources}"
    pesterm_assemble_bundle "$APP_BUNDLE" "$BUILT_BIN"

    echo "==> 3/4 render Info.plist (done) + sign last"
    pesterm_sign "$APP_BUNDLE"

    echo "==> 4/4 verify signature"
    pesterm_verify_sign "$APP_BUNDLE"

    echo
    echo "Built: $APP_BUNDLE"
    echo "Inner binary: $APP_BUNDLE/Contents/MacOS/$BIN_NAME"
    echo "Bundle id: $BUNDLE_ID"
    echo
    echo "Verify signature:  codesign -dv \"$APP_BUNDLE\""
    echo "Run (from iTerm2):  \"$APP_BUNDLE/Contents/MacOS/$BIN_NAME\" post --message 'test'"
fi
