# Ghostty sdef Findings (Step 0 ground truth)

Dictionary dumped 2026-07-02 from Ghostty **1.3.1** (`/Applications/Ghostty.app`) with
`sdef /Applications/Ghostty.app`; `Sources/CGhosttyBridge/include/GhosttyBridge.h` was
generated from that same dump via `sdp -fh --basename Ghostty` (the executable source of
the procedure is `scripts/verify-ghostty-sdef.sh`). Every class/property/command name and
four-char code below is read verbatim from the dump — do not re-derive from docs or
training data.

## Object model (suite `Ghst`)

```
application (capp)
├── windows   (element, cocoa key scriptWindows)
├── terminals (element, cocoa key terminals — FLAT list across all windows)
└── front window (GFWn, r)

window (Gwnd)
├── id            ID    text  r   "Stable ID for this window."
├── name          pnam  text  r   (title)
├── selected tab  GWsT  tab   r
├── tabs          (element)
├── terminals     (element)
└── responds-to: activate window, close window

tab (Gtab)
├── id                ID    text     r  "Stable ID for this tab."
├── name              pnam  text     r  (title)
├── index             pidx  integer  r  1-based in its window
├── selected          GTsl  boolean  r
├── focused terminal  GTfT  terminal r
├── terminals         (element)
└── responds-to: select tab, close tab

terminal (Gtrm)
├── id                 ID    text  r  "Stable ID for this terminal surface."
├── name               pnam  text  r  (title)
├── working directory  Gwdr  text  r  "Current working directory for the terminal process."
└── responds-to: split, focus, close
```

## Commands the revealer uses

| Command | Code | sdef description |
|---------|------|------------------|
| `activate window` | `GhstAcWn` | "Activate a Ghostty window, bringing it to the front." |
| `select tab` | `GhstSlTb` | "Select a tab in its window." |
| `focus` | `GhstFcus` | "Focus a terminal, bringing its window to the front." |

sdp generates these on the `GhosttyGenericMethods` protocol as `activateWindow`,
`selectTab`, and `focus` (no-argument sends to the receiver).

## Verified (from the dump alone)

- All three id properties are **`text`** and documented "Stable ID" — the bridge treats
  them as opaque strings end to end (no integer stringification needed, but the bridge
  still defends with `description` in case a future sdef changes the type).
- `working directory` is **`text`** (a plain string, not a `file` object), read-only,
  code `Gwdr`. Whether it is a logical or physical path is a RUNTIME question (deferred
  check 1 below) — the sdef type alone does not answer it.
- The application exposes a **flat `terminals` element** in addition to the
  window→tab→terminal hierarchy; the bridge traverses the hierarchy because the reveal
  needs the enclosing window/tab ids for the compound identity, not just the terminal.
- `focus` is documented window-fronting ("bringing its window to the front"), but whether
  it also selects the enclosing tab is unverified (deferred check 2) — hence the
  belt-and-braces sequence `activate window` + `select tab` + `focus` is mandatory.
- id **uniqueness scope** (globally unique across the app vs per-window/per-tab counters)
  is not stated by the sdef. The bridge carries the compound `(windowId, tabId,
  terminalId)` unconditionally, so this verdict only decides whether the window/tab
  components are load-bearing for the re-find or redundant belt-and-braces. Record the
  verdict when the live checks run.

## DEFERRED live checks (plan addendum — run on the user's machine, M-series acceptance)

These require a human at a live Ghostty ≥ 1.3 session (TCC prompts, Script Editor). Until
they land, the precise tier ships at bounded risk: every miss degrades to app-front.

1. **Logical-vs-physical path gate (GO/NO-GO for the precise tier).** In a shell whose
   `$PWD` is a logical/symlinked path (`cd /tmp` → `$PWD` = `/tmp`, physical
   `/private/tmp`), compare `$PWD` against the `working directory` AppleScript reports
   for that terminal. Record: agree raw / agree only after resolving symlinks on both
   sides / systematically diverge. **Record the actual observed `$PWD`/`working
   directory` string pairs verbatim — they replace the PROVISIONAL symlink fixtures in
   `GhosttyEnvTests` (`normalizePath`).** If they diverge beyond symlink resolution, the
   precise tier is dead weight — re-scope to `.appOnly` per the plan's NO-GO scope.
2. **Focus-vs-tab-selection.** Does `focus` on a background-tab terminal raise the window
   AND select its tab by itself, or is the explicit `activate window` + `select tab`
   required? Record which sends were necessary. (The shipped sequence sends all three
   regardless; this check decides whether that can ever be slimmed.)
3. **Shell-integration-off behavior.** With Ghostty shell integration disabled, is
   `working directory` missing, empty, or stale? Record what the traversal yields — the
   bridge maps a nil cwd to `""`, which can never match a captured `$PWD`, so the
   expected degrade is app-front + no-match diagnostic.

Also record while there (from Step 0 item 2d): whether `terminal.id` values repeat across
windows/tabs (uniqueness scope), and whether `working directory` carries a trailing slash
or `file://` prefix in practice (the raw values feed `normalizePath` fixtures).
