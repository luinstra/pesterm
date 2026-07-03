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

## Live checks — RESULTS (run 2026-07-02 against Ghostty 1.3.1, driven via osascript
## from a tmux-attached session; TCC Automation grant approved live)

1. **Logical-vs-physical path gate: ✅ GO.** A tab created with initial working directory
   `/tmp` (a symlink to `/private/tmp`) reports `working directory` = `/tmp` — the
   LOGICAL path, byte-identical to what `$PWD` reports in that shell. Observed pair:
   `$PWD` semantics `/tmp` ↔ reported `[/tmp]`. The raw normalized compare is the hot
   path; the symlink-resolved retry in `chooseTerminal` stays as belt-and-braces for
   exotic setups but was NOT needed. Additional observed pair from a real session:
   reported `[/Volumes/Dock/Dev/luinstra/pesterm]` for a shell in that directory —
   clean POSIX path, NO trailing slash, NO `file://` prefix. The precise tier is live.
2. **Focus-vs-tab-selection: `focus` alone does BOTH.** With a different tab selected,
   sending `focus` to a background tab's terminal fronted the window AND flipped that
   tab's `selected` to true, with no explicit `activate window`/`select tab` sends.
   The shipped belt-and-braces sequence is confirmed harmless redundancy — KEEP it
   (preview API; the explicit sends cost nothing and survive semantic drift).
3. **Shell-integration-off behavior: STILL DEFERRED** (requires a config flip + Ghostty
   restart — not worth disturbing a live session). Low stakes: the bridge maps a nil
   cwd to `""`, `chooseTerminal` refuses to match an empty key (guard test), so the
   expected degrade is app-front + no-match diagnostic regardless of what it yields.

Step 0 item 2d verdict: **terminal ids are UUIDs** (e.g.
`83C92FB7-6B1E-40AF-87EA-27E266BE3BF3`) — globally unique by construction; window/tab
ids are prefixed strings (`tab-group-858403c00` / `tab-858d4ce00`). The compound
`(windowId, tabId, terminalId)` carry is therefore redundant belt-and-braces for the
re-find, exactly the safe case — no change needed.

Scripting notes for future maintenance: the application-level `new tab` command errors
with `-1708` unless addressed `in <window>` (use `new tab in (front window) with
configuration cfg`); `working directory` tracks the cwd correctly even for a
tmux-attached shell (shell integration reports through the attach).
