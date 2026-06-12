# pesterm

> **Tech Stack:** Swift 5.9 (SwiftPM), AppKit, UserNotifications, ScriptingBridge — native macOS, no runtime deps but swift-argument-parser
> **Build:** `swift build` · **Test:** `swift test` · **Ship:** `scripts/build-app.sh` then `scripts/install.sh`
> **Platform floor:** macOS 11 (Big Sur)

## Overview

pesterm is a CLI agent's way of pestering you back to the right terminal tab. A coding
agent (Claude Code) fires a hook → pesterm posts a native macOS notification → clicking it
**reveals the exact iTerm2 tab** that needs attention. For tool-permission prompts it goes
further: the notification carries **Approve/Deny** buttons, and pesterm **blocks** until you
tap one, then hands the decision back to Claude.

It runs as a short-lived, ad-hoc-signed `.app` bundle (`LSUIElement`/accessory — no Dock,
no menu bar). Each notification is a **fresh process** that posts, waits, acts, and exits.

## Architecture

One executable, invoked per-event. `main.swift` builds a request from args/stdin, *then*
spins up AppKit so the notification can deliver and its callbacks fire. The flow is layered:

```
hook JSON ─▶ Adapters ─▶ NotificationRequest ─▶ Notifications backend ─▶ macOS
(stdin)                                                  │
                                          tap ──▶ Reveal (iTerm2) / Permission decision
```

| Layer | Dir | Job |
|-------|-----|-----|
| Entry / lifecycle | `Sources/pesterm/main.swift`, `AppDelegate.swift` | Build request BEFORE `app.run()`; post on launch |
| Adapters | `Sources/pesterm/Adapters/` | Claude hook JSON → request; permission decision → JSON |
| Notifications | `Sources/pesterm/Notifications/` | `UNUserNotificationCenter` post + delegate callbacks |
| Permission | `Sources/pesterm/Permission/` | Blocking Approve/Deny flow, one-shot gate, fail-safe |
| Reveal | `Sources/pesterm/Reveal/` | Bring the iTerm2 tab/session forward (ScriptingBridge) |
| Wiring | `Sources/pesterm/Wiring/` | Surgically edit `~/.claude/settings.json` hooks |
| CLI | `Sources/pesterm/CLI/` | `configure`/`status`/`sounds`/`sample`/`post`/`unwire` |
| Sounds | `Sources/pesterm/Sounds/` | Named system-sound catalog |
| C bridge | `Sources/CITermBridge/` | Generated iTerm2 ScriptingBridge umbrella header |

## Quick Commands

| Command | Purpose |
|---------|---------|
| `swift build` | Compile (the only truth — trust this over SourceKit, see below) |
| `swift test` | Run the unit suite (pure logic is exhaustively tested) |
| `scripts/build-app.sh` | Assemble + ad-hoc-sign `pesterm.app` |
| `scripts/install.sh` | Build, install to `~/.local/share/pesterm`, hand off to `configure` |
| `pesterm configure` | Guided front door: wire Claude hooks + check the notifications grant |
| `pesterm status` | Show what's wired and the grant state |
| `pesterm sample` | Post a test notification |
| `pesterm sounds` | List the named sounds |

## Documentation Index

| Guide | Coverage |
|-------|----------|
| [Adapters](./Sources/pesterm/Adapters/CLAUDE.md) | Hook-JSON in, decision-JSON out — the Claude contract |
| [Permission](./Sources/pesterm/Permission/CLAUDE.md) | The blocking Approve/Deny flow and its race discipline |
| [Wiring](./Sources/pesterm/Wiring/CLAUDE.md) | Non-destructive `settings.json` hook surgery |
| [DESIGN.md](./DESIGN.md) | Full design spec — invariants, gotchas, decision contract (§11a) |
| [SETUP.md](./SETUP.md) | End-user install + the one-time notifications grant |

## Hard Invariants (don't regress these)

1. **Reveal target comes from the ENV, never the payload.** `ITERM_SESSION_ID` is read
   from the inherited terminal env; the agent's JSON `session_id` is only a human-readable
   label. The hook runs *inside* the terminal — the env is the source of truth.
2. **Build the request, THEN `app.run()`.** `main.swift` reads stdin and parses args before
   constructing `NSApplication`. ArgumentParser only *builds*; it must never spin the run
   loop. See the GUARD NOTE in `main.swift` before adding any subcommand that needs to post.
3. **Every adapter exit is `exit(0)`.** Suppressed event, unknown tool, invalid JSON,
   permission timeout — all exit 0 so Claude falls back to its own terminal UI. A non-zero
   exit would look like a hook failure. **Never auto-allow on a fallback.**
4. **The permission hook BLOCKS.** It posts, keeps the run loop alive up to 120s waiting for
   a human tap, writes the decision JSON to stdout, then exits 0. See the Permission guide.
5. **Approvals are NOTIFICATION buttons, never a modal.** No focus-stealing window — a
   product decision, not an accident. Don't "upgrade" it to an alert panel.

## Common Mistakes

❌ Reading the reveal target from the agent payload.
✅ Read `ITERM_SESSION_ID` from `env` (`iTermSessionIdFromEnv()`).

❌ Adding a subcommand that posts a notification via the run-and-exit fallthrough in
   `main.swift` — it `exit(0)`s before `app.run()`, so nothing delivers.
✅ Route it through the request-building path like `post`/the adapters.

❌ Exiting non-zero on a bad/empty payload.
✅ Log to stderr and `exit(0)` — fall back to Claude's terminal prompt.

❌ Using bash 4+ features in `scripts/*.sh`. macOS ships `/bin/bash` 3.2.57 — no
   `shopt -s inherit_errexit`, no associative arrays.
✅ Guard with `if ! VAR="$(...)"; then …; fi`.

❌ Trusting SourceKit "Cannot find X in scope" on a freshly added file.
✅ Verify with `swift build` / `swift test` — the stale index lies; the compiler doesn't.
