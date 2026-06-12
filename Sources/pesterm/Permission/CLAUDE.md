# Permission — Claude Code Guidance

> **Context:** The blocking Approve/Deny flow. pesterm posts a notification, **waits** for a human tap (up to 120s), writes the decision Claude reads, and exits.
> **Parent Guide:** [Project Root](../../../CLAUDE.md)
> **See Also:** [Adapters](../Adapters/CLAUDE.md) · [Notifications backend](../Notifications/UNUserNotificationBackend.swift) · [DESIGN.md §11a](../../../DESIGN.md)

## Quick Reference

A `PermissionRequest` hook is **blocking**: Claude waits on the hook's stdout to decide
whether to run the tool. pesterm exploits that — it posts a `.permission` notification and
keeps the AppKit run loop alive while you decide. The lifecycle:

```
post() ─ arm 120s fail-safe FIRST ─ requestAuthorization ─ schedule notification
                                                                    │
   ┌──────────────────────── exactly one wins (ResolvedGate) ───────┼─────────────┐
   ▼                                                                 ▼             ▼
Approve/Deny tap                                          body/default click   120s fail-safe
 → write decision JSON                                     → REVEAL tab,        → emit NOTHING
 → fflush + exit 0                                           keep waiting        → exit 0 (fallback)
```

The pure helpers live here; the delegate methods that call them live in
`Notifications/UNUserNotificationBackend.swift`. Read both together.

## Structure

```
Permission/
├── PermissionFlow.swift   # constants + pure action-id → decision mapping; timeoutSeconds = 120
├── ResolvedGate.swift     # one-shot NSLock finalizer: tryResolve() returns true to exactly one caller
└── GrantStatus.swift      # pure-CLI reader for the notifications grant (status/configure)
```

## Key Patterns

### Exactly one finalizer wins (`ResolvedGate`)

Two racers can fire: the Approve/Deny tap and the 120s fail-safe timer. `gate.tryResolve()`
returns `true` to the **first** caller and `false` forever after, atomically. The winner
emits + exits; the loser does nothing. This is what prevents a double-emit / double-exit /
a timer firing *after* a tap already answered.

### The fail-safe is armed BEFORE `requestAuthorization`

In `post()`, the 120s timer is scheduled *first* — before the auth prompt — so an
unanswered first-run authorization dialog still falls back instead of hanging forever (the
"auth-gap" fix). On fire it emits **nothing** and `exit(0)`: a terminal fallback, **never**
an auto-allow. 120s must stay well under Claude's ~600s hook timeout so pesterm wins the
race and Claude gets a clean fallback rather than its own timeout.

### Body click = REVEAL, not resolve

Tapping the notification *body* (the default action) reveals the iTerm2 tab and **returns
without resolving** — the run loop keeps waiting, the fail-safe keeps running. Only the
Approve/Deny action buttons map to a decision (`PermissionFlow.decision(forActionIdentifier:)`
returns nil for the body/unknown). `AppDelegate` double-guards so an action tap never also
reveals.

### Every path exits 0

allow/deny → `(json, 0)`; timeout → `(nil, 0)`. There is no non-zero exit in this flow — a
non-zero code reads as a hook failure to Claude.

## ⚠️ Active Investigation: approvals broke on Claude Code 2.1.168

Validated working on **2.1.165**; on **2.1.168** the symptom is "Approve works, tool still
blocked" — pesterm writes the allow JSON but Claude doesn't honor it. pesterm's decision-
writing code is **byte-identical** since the feature shipped, so the dead link is the
*consumer*. Two live hypotheses:

1. **Slow-hook race (Claude-side).** GitHub #12176: when a hook returns `{behavior: allow}`
   but takes longer than ~1–2s, the permission dialog may already be showing and the
   decision is dropped. pesterm's hook is *always* slow (it waits for a human). Fails even
   with a single isolated prompt.
2. **Multi-process tap-misrouting (pesterm-side).** Every concurrent permission is a
   separate process, all under bundle id `com.luinstra.pesterm`, each a notification-center
   delegate. A tap may route to the wrong process → decision written to the wrong stdout →
   the originating hook times out. Only reproduces with 2+ concurrent prompts.

**Instrumentation exists** on the `debug-permission-logging` branch (NOT merged):
`Permission/DebugLog.swift` + log lines in the backend/main, gated by a `~/.pesterm-debug`
marker file, writing to `~/.pesterm-debug.log`. The discriminator: a solo prompt isolates
#1; a concurrent pair exposes #2. **Strip that instrumentation before any real merge.**

If the fix turns out architectural, the likely shape is **decoupling tap-receipt from
decision-return** — e.g. a per-request decision file that the originating process polls —
so a misrouted tap still reaches the right waiter.

## Common Mistakes

❌ **Resolving on a body click.**
```swift
onActivate?(id); gate.tryResolve(); exit(0)   // kills the wait on a mere reveal
```
✅ **Body/unknown id → reveal and return; only Approve/Deny resolve.**
```swift
guard let decision = PermissionFlow.decision(forActionIdentifier: id) else {
    onActivate?(id); completionHandler(); return   // keep waiting
}
```

❌ **Arming the fail-safe after `requestAuthorization`** — a never-answered first-run auth
prompt then hangs the hook with no fallback.
✅ **Arm it at `post()` entry, before auth.**

❌ **Auto-allowing on timeout** to "be helpful."
✅ **Emit nothing + exit 0.** Silence falls back to Claude's prompt; it never approves.

## Working Here Checklist

- [ ] Every new terminal path goes through `gate.tryResolve()` and `exit(0)`
- [ ] The fail-safe stays armed before auth and ≤120s
- [ ] Decisions come only from action ids; body/unknown reveals without resolving
- [ ] No debug instrumentation rode along into the merge
- [ ] If you touched the decision JSON, re-check the [Adapters](../Adapters/CLAUDE.md) contract

## Related Guides

- [Adapters](../Adapters/CLAUDE.md) — builds the `.permission` request and the decision JSON
- [DESIGN.md §11a](../../../DESIGN.md) — the locked decision contract and rationale
