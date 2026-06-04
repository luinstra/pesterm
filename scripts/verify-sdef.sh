#!/usr/bin/env bash
#
# verify-sdef.sh — verify-don't-guess gate (Task 4a). Confirms the LOCALLY INSTALLED
# iTerm2's scripting dictionary exposes the surface the revealer depends on:
#   - session class has a read-only `id` property (the GUID we match on), and
#   - `select` is a command applicable to session/tab/window.
# Then (re)generates the PRIMARY ScriptingBridge header and vendors it in-tree.
#
# Run from the repo root: scripts/verify-sdef.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITERM_APP="/Applications/iTerm.app"
SDEF_OUT="/tmp/iterm.sdef"
HEADER_DST="$REPO_ROOT/Sources/CITermBridge/include/iTermBridge.h"

if [[ ! -d "$ITERM_APP" ]]; then
    echo "error: iTerm2 not installed at $ITERM_APP" >&2
    echo "       (Phase 1 reveal targets iTerm2; install it then re-run.)" >&2
    exit 1
fi

echo "==> dumping iTerm2 .sdef"
sdef "$ITERM_APP" > "$SDEF_OUT"

echo "==> checking for session.id property"
if grep -q '<property name="id"' "$SDEF_OUT"; then
    echo "    OK: 'id' property present"
else
    echo "error: 'id' property NOT found in iTerm2 .sdef — reveal match key missing" >&2
    exit 1
fi

echo "==> checking for select command"
if grep -q '<command name="select"' "$SDEF_OUT"; then
    echo "    OK: 'select' command present"
else
    echo "error: 'select' command NOT found in iTerm2 .sdef — reveal cannot focus" >&2
    exit 1
fi

echo "==> checking session responds-to select"
if grep -q 'responds-to command="select"' "$SDEF_OUT"; then
    echo "    OK: a class responds-to 'select'"
else
    echo "warning: no explicit responds-to select found (select may still apply)" >&2
fi

echo "==> generating PRIMARY ScriptingBridge header (sdp -fh)"
sdef "$ITERM_APP" | sdp -fh --basename iTermBridge -o /tmp
if [[ -f /tmp/iTermBridge.h ]]; then
    cp /tmp/iTermBridge.h "$HEADER_DST"
    echo "    OK: vendored header at $HEADER_DST"
else
    echo "error: sdp did not produce /tmp/iTermBridge.h" >&2
    exit 1
fi

echo
echo "sdef verification PASSED: id + select present; header regenerated."
echo "NOTE (PP2): that ScriptingBridge session.id EQUALS the env ITERM_SESSION_ID GUID"
echo "            (last colon-component) is a RUNTIME assumption — confirm in a live"
echo "            iTerm2 session by comparing 'echo \$ITERM_SESSION_ID' (after ##*:)"
echo "            with the id read during reveal."
