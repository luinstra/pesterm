#!/usr/bin/env bash
#
# verify-ghostty-sdef.sh — verify-don't-guess gate for the Ghostty revealer (the
# Ghostty mirror of verify-sdef.sh). Confirms the LOCALLY INSTALLED Ghostty's
# scripting dictionary still exposes the surface the revealer depends on:
#   - terminal class has `id` and `working directory` properties, and
#   - the `focus`, `select tab`, and `activate window` commands exist.
# Then regenerates the vendored ScriptingBridge header WITHOUT clobbering the
# hand-written pesterm_ghostty_* declarations appended after the marker line
# (verify-sdef.sh's blind `cp` would destroy them — do not inherit that).
#
# DEV-MACHINE-ONLY, like verify-sdef.sh: never wire this into CI or into
# `swift build`/`swift test` — headless machines have no Ghostty. The header is
# vendored in-tree precisely so builds never need the app.
#
# macOS ships bash 3.2 — no bash-4 features in here.
#
# Run from the repo root: scripts/verify-ghostty-sdef.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GHOSTTY_APP="/Applications/Ghostty.app"
SDEF_OUT="/tmp/Ghostty.sdef"
GEN_OUT="/tmp/Ghostty.h"
HEADER_DST="$REPO_ROOT/Sources/CGhosttyBridge/include/GhosttyBridge.h"
# The line that begins the hand-written portion of the vendored header.
MARKER="==== pesterm additions"

if [[ ! -d "$GHOSTTY_APP" ]]; then
    echo "error: Ghostty not installed at $GHOSTTY_APP" >&2
    echo "       (the Ghostty reveal needs Ghostty >= 1.3; install it then re-run.)" >&2
    exit 1
fi

echo "==> dumping Ghostty .sdef"
sdef "$GHOSTTY_APP" > "$SDEF_OUT"

echo "==> checking terminal properties (id, working directory)"
# Scope the property checks to the TERMINAL class block — a global grep would let a
# window/tab id mask a vanished terminal.id (the property the reveal matches on).
TERMINAL_BLOCK="$(sed -n '/<class name="terminal"/,/<\/class>/p' "$SDEF_OUT")"
if [[ -z "$TERMINAL_BLOCK" ]]; then
    echo "error: no <class name=\"terminal\"> block in Ghostty .sdef" >&2
    exit 1
fi
if echo "$TERMINAL_BLOCK" | grep -q '<property name="id"'; then
    echo "    OK: terminal 'id' property present"
else
    echo "error: terminal 'id' property NOT found in Ghostty .sdef — reveal identity missing" >&2
    exit 1
fi
if echo "$TERMINAL_BLOCK" | grep -q '<property name="working directory"'; then
    echo "    OK: terminal 'working directory' property present"
else
    echo "error: terminal 'working directory' NOT found in Ghostty .sdef — cwd match key missing" >&2
    exit 1
fi

echo "==> checking commands (focus, select tab, activate window)"
for cmd in "focus" "select tab" "activate window"; do
    if grep -q "<command name=\"$cmd\"" "$SDEF_OUT"; then
        echo "    OK: '$cmd' command present"
    else
        echo "error: '$cmd' command NOT found in Ghostty .sdef — reveal cannot front" >&2
        exit 1
    fi
done

echo "==> regenerating ScriptingBridge header (sdp -fh --basename Ghostty)"
rm -f "$GEN_OUT"
sdp -fh --basename Ghostty -o /tmp "$SDEF_OUT"
if [[ ! -f "$GEN_OUT" ]]; then
    echo "error: sdp did not produce $GEN_OUT" >&2
    exit 1
fi

echo "==> re-vendoring header, preserving the pesterm_ghostty_* declarations"
if ! grep -q "$MARKER" "$HEADER_DST"; then
    echo "error: marker '$MARKER' not found in $HEADER_DST — refusing to rewrite" >&2
    echo "       (the hand-written declarations could not be located to preserve them)" >&2
    exit 1
fi
MARKER_LINE="$(grep -n "$MARKER" "$HEADER_DST" | head -1 | cut -d: -f1)"
# The appended block starts at the comment opener one line above the marker.
APPEND_START=$((MARKER_LINE - 1))
# Preamble = the vendored file's own comment block, i.e. everything before its first
# #import; generated body = everything from the first #import of the fresh sdp output
# (dropping sdp's own "/* Ghostty.h */" comment).
DST_IMPORT_LINE="$(grep -n '^#import' "$HEADER_DST" | head -1 | cut -d: -f1)"
GEN_IMPORT_LINE="$(grep -n '^#import' "$GEN_OUT" | head -1 | cut -d: -f1)"
if [[ -z "$DST_IMPORT_LINE" || -z "$GEN_IMPORT_LINE" ]]; then
    echo "error: could not locate #import lines to splice the header — refusing" >&2
    exit 1
fi
TMP_HEADER="$(mktemp /tmp/GhosttyBridge.h.XXXXXX)"
{
    sed -n "1,$((DST_IMPORT_LINE - 1))p" "$HEADER_DST"
    sed -n "${GEN_IMPORT_LINE},\$p" "$GEN_OUT"
    echo ""
    sed -n "${APPEND_START},\$p" "$HEADER_DST"
} > "$TMP_HEADER"
mv "$TMP_HEADER" "$HEADER_DST"
echo "    OK: vendored header at $HEADER_DST (pesterm additions preserved)"

echo
echo "Ghostty sdef verification PASSED: id + working directory + focus/select/activate present."
echo "NOTE: whether \$PWD (logical) equals the reported 'working directory' (possibly"
echo "      physical) is a RUNTIME question — see docs/ghostty-sdef-findings.md,"
echo "      deferred check 1, before trusting the precise tier on a new Ghostty version."
