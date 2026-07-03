#!/usr/bin/env bash
#
# install.sh — no-sudo, direct-build install of pesterm (the terminal-notifier model).
#
# Builds the release binary, assembles + ad-hoc-signs the .app bundle, places it under
# $PREFIX/share/pesterm, registers it with LaunchServices, symlinks $PREFIX/bin/pesterm,
# proves the bundle identity THROUGH the symlink, then HANDS OFF to `pesterm configure`
# (the guided flow that wires the hooks and reports/links the manual GUI grants).
#
#   PREFIX defaults to $HOME/.local; override with PESTERM_PREFIX.
#   No sudo. Idempotent — safe to re-run.
#
# Codesign hygiene (R3): we sign the bundle ONLY AFTER final placement at $PREFIX and
# never mutate it afterward, then verify --strict. A broken signature fails the install.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Reuse build-app.sh's assemble/sign helpers (sourcing does NOT run its standalone build).
# shellcheck source=scripts/build-app.sh
source "$REPO_ROOT/scripts/build-app.sh"

BUNDLE_ID="com.luinstra.pesterm"
BIN_NAME="pesterm"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# 1. PREFIX.
PREFIX="${PESTERM_PREFIX:-$HOME/.local}"
SHARE_DIR="$PREFIX/share/pesterm"
APP="$SHARE_DIR/pesterm.app"
BIN_DIR="$PREFIX/bin"
SYMLINK="$BIN_DIR/$BIN_NAME"
INNER_BIN="$APP/Contents/MacOS/$BIN_NAME"

echo "==> pesterm install — PREFIX=$PREFIX"

# 2. Ensure target dirs.
mkdir -p "$SHARE_DIR"
mkdir -p "$BIN_DIR"

# Staging bundle lives in the SAME directory as the final $APP, so the final swap is
# an atomic rename on the same filesystem (no cross-device copy mid-swap).
STAGE_APP="$SHARE_DIR/.pesterm.app.staging"
OLD_APP="$SHARE_DIR/.pesterm.app.old"
STAGE_INNER_BIN="$STAGE_APP/Contents/MacOS/$BIN_NAME"

# Clean any leftover staging/old dirs from a previous interrupted run (these are NOT
# the live install, so removing them is safe).
rm -rf "$STAGE_APP"
rm -rf "$OLD_APP"

# 3. Build + assemble + sign + verify the STAGING bundle. ALL verification happens on
#    the staging copy BEFORE we touch the existing install — a failure here leaves the
#    prior working install completely intact (failure-atomic).
# A failed `swift build` inside this command substitution must abort the install rather
# than silently bundle a stale binary. `set -e` does NOT propagate out of $(...) on its
# own (and `shopt -s inherit_errexit` needs bash 4.4+, but macOS ships bash 3.2), so we
# guard the assignment explicitly — this works on stock /bin/bash.
echo "==> Building release binary"
if ! BUILT_BIN="$(pesterm_build_release)"; then
    echo "pesterm: build failed; aborting install (no stale binary shipped)." >&2
    exit 1
fi

echo "==> Assembling bundle (staging at $STAGE_APP)"
pesterm_assemble_bundle "$STAGE_APP" "$BUILT_BIN"

echo "==> Signing (ad-hoc) staged bundle + verifying"
pesterm_sign "$STAGE_APP"
if ! pesterm_verify_sign "$STAGE_APP"; then
    echo "error: codesign --verify --deep --strict FAILED for staged bundle $STAGE_APP" >&2
    rm -rf "$STAGE_APP"
    exit 1
fi

# 4. Bundle-identity self-check against the STAGED bundle (Risk 1 / R2), running its
#    inner binary directly. We assert identity BEFORE swapping into place so a bad
#    bundle never displaces a working install.
echo "==> Verifying staged bundle identity (running $STAGE_INNER_BIN)"
STAGE_IDENTITY="$("$STAGE_INNER_BIN" status --print-identity)"
echo "$STAGE_IDENTITY"
STAGE_GOT_ID="$(printf '%s\n' "$STAGE_IDENTITY" | awk -F': ' '/^bundleIdentifier:/ {print $2}')"
STAGE_GOT_PATH="$(printf '%s\n' "$STAGE_IDENTITY" | awk -F': ' '/^bundlePath:/ {print $2}')"

if [[ "$STAGE_GOT_ID" != "$BUNDLE_ID" ]]; then
    echo "error: staged bundle identity check FAILED: got '$STAGE_GOT_ID', expected '$BUNDLE_ID'" >&2
    echo "       NSBundle.main did not resolve the staged .app." >&2
    rm -rf "$STAGE_APP"
    exit 1
fi
case "$STAGE_GOT_PATH" in
    "$STAGE_APP"|"$STAGE_APP"/*)
        : # bundlePath is inside the staged .app — good.
        ;;
    *)
        echo "error: staged bundlePath '$STAGE_GOT_PATH' is NOT inside the staged bundle '$STAGE_APP'" >&2
        rm -rf "$STAGE_APP"
        exit 1
        ;;
esac
echo "    staged identity OK: $STAGE_GOT_ID @ $STAGE_GOT_PATH"

# 5. Atomic swap into place. Only NOW — after every check on the staging copy passed —
#    do we touch the existing install. Move the old bundle aside, move staging into
#    place, and on success delete the old copy; if the swap fails, restore the old.
echo "==> Swapping staged bundle into place at $APP"
if [[ -e "$APP" ]]; then
    mv "$APP" "$OLD_APP"
fi
if ! mv "$STAGE_APP" "$APP"; then
    echo "error: failed to move staged bundle into place; restoring previous install" >&2
    if [[ -e "$OLD_APP" ]]; then
        mv "$OLD_APP" "$APP"
    fi
    exit 1
fi
rm -rf "$OLD_APP"

# 6. Register with LaunchServices — and sweep STRAY registrations of our bundle id.
#    Notification relaunch resolves by bundle id across EVERY registered copy, so a
#    stale pesterm.app (repo build artifact, backup clone) can end up answering
#    notification clicks with old code (live-debugged 2026-07-02: seven registered
#    copies, June 13 binaries handling taps). The installed app lives under a dot-dir
#    (~/.local) that Spotlight never indexes, so anything mdfind CAN see is a stray.
#    Sweeping on EVERY install makes this self-healing: a stray that Spotlight
#    re-registers later is swept again on the next install. Unregistering touches no
#    files (reversible); mdfind and lsregister are best-effort (unindexed volumes /
#    support-tool location may vary) — failures degrade to today's behavior.
echo "==> Registering bundle with LaunchServices (+ sweeping stray registrations)"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP"
    if command -v mdfind >/dev/null 2>&1; then
        # `|| true`: a failing mdfind must degrade to "no sweep", not abort the
        # install (set -o pipefail would otherwise kill the script here).
        { mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null || true; } \
        | while IFS= read -r stray; do
            [[ -z "$stray" || "$stray" == "$APP" ]] && continue
            if "$LSREGISTER" -u "$stray"; then
                echo "    unregistered stray copy: $stray"
            else
                echo "warning: could not unregister stray copy: $stray" >&2
            fi
        done
    else
        echo "warning: mdfind not found (skipping stray-registration sweep)" >&2
    fi
else
    echo "warning: lsregister not found at $LSREGISTER (skipping)" >&2
fi

# 7. CLI entry at $PREFIX/bin/pesterm.
#
#   DEVIATION from the plan's `ln -sfn` symlink (Risk 1, caught by the R2 self-check):
#   a bare symlink into the bundle's MacOS dir does NOT let NSBundle.main resolve the
#   .app — when invoked via the symlink, `_NSGetExecutablePath` reports the symlink
#   path in $PREFIX/bin, so Bundle.main.bundlePath becomes $PREFIX/bin (identity = nil)
#   and notifications would post WITHOUT the bundle identity. This is exactly the
#   failure Risk 1 warned about.
#
#   The proven terminal-notifier model uses an EXEC WRAPPER SCRIPT in bin/ that
#   `exec`s the inner binary by its real absolute path, so the process's executable
#   path is genuinely inside the .app and Bundle.main resolves correctly. We do the
#   same. The stable $PREFIX/bin/pesterm path (pinned into the hook via
#   --command-path) is preserved.
echo "==> Writing CLI wrapper $SYMLINK -> exec $INNER_BIN"
mkdir -p "$BIN_DIR"
# Remove any existing bin entry FIRST. If it's a symlink into the bundle, a `cat >`
# redirect would FOLLOW it and overwrite the freshly-signed inner binary with this
# wrapper — corrupting the bundle. `rm -f` guarantees we write a fresh regular file.
rm -f "$SYMLINK"
# Single-quote-escape the baked inner-binary path so the wrapper is robust to `$`,
# backticks, etc. in the install prefix. POSIX rule: wrap in single quotes and rewrite
# every embedded `'` as `'\''`. `"$@"` MUST stay double-quoted to forward args verbatim.
INNER_BIN_Q=$(printf "%s" "$INNER_BIN" | sed "s/'/'\\\\''/g")
cat > "$SYMLINK" <<WRAPPER
#!/bin/bash
exec '$INNER_BIN_Q' "\$@"
WRAPPER
chmod +x "$SYMLINK"

# 8. Identity self-check THROUGH the bin/ entry (Risk 1 / R2 — authoritative proof).
echo "==> Verifying bundle identity through $SYMLINK"
IDENTITY="$("$SYMLINK" status --print-identity)"
echo "$IDENTITY"
GOT_ID="$(printf '%s\n' "$IDENTITY" | awk -F': ' '/^bundleIdentifier:/ {print $2}')"
GOT_PATH="$(printf '%s\n' "$IDENTITY" | awk -F': ' '/^bundlePath:/ {print $2}')"

if [[ "$GOT_ID" != "$BUNDLE_ID" ]]; then
    echo "error: bundle identity check FAILED: got '$GOT_ID', expected '$BUNDLE_ID'" >&2
    echo "       NSBundle.main did not resolve the installed .app through the symlink." >&2
    exit 1
fi
case "$GOT_PATH" in
    "$APP"|"$APP"/*)
        : # bundlePath is inside the installed .app — good.
        ;;
    *)
        echo "error: bundlePath '$GOT_PATH' is NOT inside the installed bundle '$APP'" >&2
        exit 1
        ;;
esac
echo "    identity OK: $GOT_ID @ $GOT_PATH"

# 9. Decide how to reference pesterm in the hook, based on PATH.
#
#   If $BIN_DIR is already on PATH, bake the BARE command name `pesterm` into the hook
#   instead of the absolute $PREFIX/bin path. It resolves via PATH to this same exec
#   wrapper (so bundle identity is preserved — the wrapper still execs the inner binary),
#   and it keeps the settings entry relocatable / less machine-specific. If $BIN_DIR is
#   NOT on PATH, pin the absolute $SYMLINK so the hook fires regardless of PATH.
#
#   Caveat: hooks run in Claude Code's process environment. This uses the PATH of the
#   shell that ran install.sh as the proxy for it — normally the same login-shell PATH,
#   but if Claude Code launches with a narrower PATH that omits $BIN_DIR, re-run with
#   $BIN_DIR off PATH (or just re-install) to fall back to the absolute pin.
norm() {
    local p
    p="$(cd "$1" 2>/dev/null && pwd -P || echo "$1")"
    while [[ "$p" != "/" && "$p" == */ ]]; do p="${p%/}"; done
    printf '%s' "$p"
}
TARGET="$(norm "$BIN_DIR")"
ON_PATH=0
IFS=':' read -ra PATH_ENTRIES <<< "$PATH"
for entry in "${PATH_ENTRIES[@]}"; do
    [[ -z "$entry" ]] && continue
    if [[ "$(norm "$entry")" == "$TARGET" ]]; then
        ON_PATH=1
        break
    fi
done
if [[ "$ON_PATH" -eq 1 ]]; then
    CMD_PATH="$BIN_NAME"
else
    CMD_PATH="$SYMLINK"
fi

# 10. PATH report (ON_PATH/CMD_PATH computed in step 9). Reported BEFORE configure so
#     configure's summary (wired hooks + live grant state + Alert-Style FYI) is the LAST
#     thing the user sees.
echo "==> Checking PATH"
if [[ "$ON_PATH" -eq 0 ]]; then
    echo "    $BIN_DIR is NOT on your PATH. Add this to your shell profile:"
    echo
    echo "      export PATH=\"$BIN_DIR:\$PATH\""
    echo
    echo "    (The hook is pinned to the absolute path $SYMLINK, so it fires regardless;"
    echo "     adding $BIN_DIR to PATH also lets you run \`pesterm\` directly.)"
else
    echo "    $BIN_DIR is on PATH — the hook is wired as the bare command \`$BIN_NAME\`."
fi

# 11. Hand off to the guided `configure` flow. configure OWNS the setup UX: it wires both
#     hooks (tool approvals ON by default), then reports LIVE grant state and offers to
#     deep-link any missing System Settings pane. It runs INTERACTIVELY at a terminal and
#     AUTO-DEGRADES to defaults when there's no TTY (curl|bash / CI) — so we do NOT pass
#     --yes in the normal path. We invoke it through the known-good $SYMLINK; only the
#     baked --command-path varies. To install WITHOUT approvals, the user re-runs
#     `pesterm configure claude --no-approvals` (or answers "n" at the approvals prompt).
#
#     NOTE: NSHomeDirectory() resolves the real home via getpwuid() and IGNORES $HOME for
#     a non-sandboxed binary, so configure targets the real ~/.claude/settings.json. For a
#     SAFE install dry-run against a temp file, set PESTERM_SETTINGS (test-only; --yes there
#     to stay non-interactive).
echo
if [[ -n "${PESTERM_SETTINGS:-}" ]]; then
    echo "==> Configuring pesterm (PESTERM_SETTINGS → $PESTERM_SETTINGS)"
    "$SYMLINK" configure claude --yes --command-path "$CMD_PATH" --settings "$PESTERM_SETTINGS"
else
    "$SYMLINK" configure claude --command-path "$CMD_PATH"
fi

echo
echo "==> Done. Restart Claude Code so it reloads ~/.claude/settings.json."
echo "    Re-run setup any time with:  pesterm configure   (already configured? it leaves"
echo "    your setup untouched — add --force to overwrite it)."
echo "    Check state any time with:   pesterm status"
