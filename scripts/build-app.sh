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

# Branding sources: both are committed, original 1024×1024 PNGs — no /Applications
# dependency. The "claude" source is our own Claude-ish mark (rust sunburst on a
# near-black terminal squircle); the generic source is the amber pesterm glyph.
# Regenerate via scripts/gen-claude-icon.swift / scripts/gen-pesterm-icon.swift.
CLAUDE_PNG="$REPO_ROOT/assets/claude-icon-1024.png"
FALLBACK_PNG="$REPO_ROOT/assets/pesterm-icon-1024.png"

# Build Contents/Resources/pesterm.icns in the bundle $1 from the 1024 PNG $2, via a
# standard macOS iconset (sips-resized 16..512 with @1x/@2x; 1024 is the 512@2x) +
# iconutil. Echoes nothing; non-zero on failure.
pesterm_build_icns_from_png() {
    local app_bundle="$1"
    local src_png="$2"
    local res_dir="$app_bundle/Contents/Resources"
    mkdir -p "$res_dir"

    local iconset
    iconset="$(mktemp -d)/pesterm.iconset"
    mkdir -p "$iconset"
    sips -z 16 16     "$src_png" --out "$iconset/icon_16x16.png"      >/dev/null
    sips -z 32 32     "$src_png" --out "$iconset/icon_16x16@2x.png"   >/dev/null
    sips -z 32 32     "$src_png" --out "$iconset/icon_32x32.png"      >/dev/null
    sips -z 64 64     "$src_png" --out "$iconset/icon_32x32@2x.png"   >/dev/null
    sips -z 128 128   "$src_png" --out "$iconset/icon_128x128.png"    >/dev/null
    sips -z 256 256   "$src_png" --out "$iconset/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$src_png" --out "$iconset/icon_256x256.png"    >/dev/null
    sips -z 512 512   "$src_png" --out "$iconset/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$src_png" --out "$iconset/icon_512x512.png"    >/dev/null
    sips -z 1024 1024 "$src_png" --out "$iconset/icon_512x512@2x.png" >/dev/null

    if ! iconutil -c icns "$iconset" -o "$res_dir/pesterm.icns"; then
        echo "error: iconutil failed to build pesterm.icns from $iconset" >&2
        rm -rf "$(dirname "$iconset")"
        return 1
    fi
    rm -rf "$(dirname "$iconset")"
    return 0
}

# Embed the bundle icon at $1 (an assembled .app) as Contents/Resources/pesterm.icns
# and set the display name in $1/Contents/Info.plist. MUST run BEFORE signing (R3):
# mutating an ad-hoc-signed bundle breaks its signature.
#
# The agent to brand for is $2 (default "claude" — the single agent today). It selects
# the ICON only; the bundle display name is ALWAYS "pesterm" so macOS attributes
# notifications, the Notifications pane, the Automation pane, and the TCC prompt to
# "pesterm" (not "Claude Code"). The agent identity lives in the notification TITLE
# (set per-adapter, e.g. "Claude Code"), which is where it belongs and where it varies.
#   - claude  → build pesterm.icns from assets/claude-icon-1024.png (our committed
#               Claude-ish mark).
#   - else    → build pesterm.icns from assets/pesterm-icon-1024.png (amber glyph).
#               Generic / unknown agents land here.
# If the claude PNG is missing, fall back to the amber generic source.
#
# Echoes "claude" or "fallback" on stdout so callers can report which path ran.
pesterm_embed_icon() {
    local app_bundle="$1"
    local agent="${2:-claude}"
    local plist="$app_bundle/Contents/Info.plist"

    if [[ "$agent" == "claude" && -f "$CLAUDE_PNG" ]]; then
        if ! pesterm_build_icns_from_png "$app_bundle" "$CLAUDE_PNG"; then
            return 1
        fi
        pesterm_set_display_name "$plist" "pesterm"
        echo "claude"
        return 0
    fi

    # Generic / fallback: build pesterm.icns from the committed amber 1024 PNG.
    if [[ ! -f "$FALLBACK_PNG" ]]; then
        echo "error: fallback icon PNG missing at $FALLBACK_PNG (run scripts/gen-pesterm-icon.swift)" >&2
        return 1
    fi
    if ! pesterm_build_icns_from_png "$app_bundle" "$FALLBACK_PNG"; then
        return 1
    fi
    pesterm_set_display_name "$plist" "pesterm"
    echo "fallback"
    return 0
}

# Set CFBundleDisplayName in $1 (a plist) to $2. Adds the key if absent.
pesterm_set_display_name() {
    local plist="$1"
    local name="$2"
    if /usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $name" "$plist"
    else
        /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $name" "$plist"
    fi
}

# Build the release binary and echo its absolute path on stdout.
pesterm_build_release() {
    if ! swift build -c release >&2; then
        echo "error: swift build -c release failed; not bundling a stale binary" >&2
        return 1
    fi
    local built
    built="$(swift build -c release --show-bin-path)/$BIN_NAME"
    if [[ ! -x "$built" ]]; then
        echo "error: built binary not found at $built" >&2
        return 1
    fi
    echo "$built"
}

# Assemble (and render Info.plist) a .app bundle at $1 from the built binary $2,
# branding for agent $3 (default "claude" — the single agent today).
# Does NOT sign — sign LAST, after all mutation and final placement (R3 / C4).
pesterm_assemble_bundle() {
    local app_bundle="$1"
    local built_bin="$2"
    local agent="${3:-claude}"

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

    # Embed the icon + set the display name BEFORE signing (R3). Echo which path ran
    # (claude vs fallback) to stderr so the caller's logs show it without polluting
    # this function's stdout (assemble has no stdout contract, but keep it clean).
    local icon_path
    if ! icon_path="$(pesterm_embed_icon "$app_bundle" "$agent")"; then
        echo "error: icon embed failed for $app_bundle" >&2
        return 1
    fi
    echo "    icon: embedded via $icon_path path (Contents/Resources/pesterm.icns)" >&2
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

    # Guard the assignment so a failed build aborts here instead of bundling a stale
    # binary — `set -e` does not propagate out of $(...) and inherit_errexit needs
    # bash 4.4+ (macOS ships 3.2).
    echo "==> 1/4 swift build -c release"
    if ! BUILT_BIN="$(pesterm_build_release)"; then
        echo "error: build failed; not assembling a stale bundle." >&2
        exit 1
    fi

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
