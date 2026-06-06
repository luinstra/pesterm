# pesterm — Design Spec

**pesterm** — your CLI agent pesters you back to the right terminal tab.

**Status:** Draft v0 · pre-implementation.

---

## 1. What it is

A native macOS app that posts a rich notification when a CLI coding-agent harness
needs your attention — and, when clicked, focuses the **exact** terminal tab the
agent is running in. It replaces the bash + `terminal-notifier` + `uv` + Python
prototype ([claude-notify-kit](https://github.com/luinstra/claude-notify-kit))
with one self-contained Swift binary.

Target harnesses: **Claude Code, Codex, Gemini CLI, Antigravity (`agy`)**.
Target terminal (v1): **iTerm2**, behind an abstraction that makes other
terminals additive.

## 2. Goals

- One native, dependency-free artifact — no `terminal-notifier` clone, no `uv`, no Python.
- Banner says **which agent** and **which project** needs you.
- Click → focus the exact terminal tab/session, **in-process**.
- Clean abstractions so new **agents** and new **terminals** are additive, not rewrites.
- macOS-native frameworks first; external scripting only where a terminal exposes no other interface.

## 3. Non-goals

- Not a general-purpose `terminal-notifier` replacement.
- macOS only (no Linux/Windows).
- Precise reveal only where the terminal exposes an interface; otherwise degrade gracefully (the banner still fires).
- Don't build agents/terminals we don't use yet — implement on demand behind the abstractions.

## 4. Background: why native (the gotchas the prototype already paid for)

The bash prototype works but is held together against four macOS realities. The
native rewrite dissolves three of them:

1. **App icon** — since Big Sur the banner shows the **posting app's** icon;
   `terminal-notifier -appIcon` is dead (private API). → A native app owns its
   identity; icon/name are native, no rebrand hack.
2. **`-sender` disables `-execute`** — faking the icon via `-sender` would kill
   the click action. → N/A once native.
3. **GUI-launched click runs with a minimal `PATH`** (`/usr/bin:/bin:/usr/sbin:/sbin`,
   no `~/.local/bin`) — shelling to `uv`/Python broke silently. → The click
   handler runs **in-process Swift**; the entire `-execute → reveal.sh → uv →
   iterm2_reveal.py` chain collapses into one method.

## 5. Architecture

Two abstraction axes (**agents** = how we're triggered, **terminals** = how we
reveal) plus a swappable **notification backend**:

```
[agent harness hook] --JSON (stdin/argv)--> [agent adapter] --CLI args--> [pesterm core]
                                                                                |
                                              +---------------------------------+--------------------+
                                              |                                                      |
                                     [NotificationBackend]                                  [TerminalRevealer]
                                  UNUserNotification                               iTerm2 via ScriptingBridge + AppKit (v1)
                                  (behind the protocol)                            other terminals later, behind the protocol
```

### Key invariant

The reveal **never reads the agent's payload** to locate the terminal. It reads
the terminal's own env var (e.g. `ITERM_SESSION_ID`), which the hook inherits
because it runs as a child of the agent in that tab. → reveal is fully
agent-agnostic; one revealer serves every agent.

## 6. Swift interfaces (sketch)

```swift
enum RevealCapability { case precise, appOnly, none }

protocol TerminalRevealer {
    /// Return a revealer if the current env identifies this terminal, else nil.
    static func detect(_ env: [String: String]) -> TerminalRevealer?
    var capability: RevealCapability { get }
    func reveal() throws              // in-process: ScriptingBridge/AppKit; CLI only as last resort
}

protocol NotificationBackend {
    func post(_ request: NotificationRequest, onActivate: @escaping () -> Void) throws
}

struct NotificationRequest {
    var title: String
    var subtitle: String?
    var body: String
    var sound: String?
    var source: AgentSource           // for branding / icon selection
    var groupID: String?              // coalesce per session
}
```

A registry holds `[TerminalRevealer.Type]`, picks the first match, iTerm2 first.
Adding a terminal = one new conformance + a registry entry. Core, notification,
and click-wiring never change.

### iTerm2 revealer (v1)

- **Detect:** `TERM_PROGRAM == "iTerm.app"` and `ITERM_SESSION_ID` present;
  session id = the part after `:` in `ITERM_SESSION_ID`.
- **Reveal (native, no subprocess):**
  - App to front → `NSRunningApplication` / `NSWorkspace` (pure AppKit).
  - Focus the session → **ScriptingBridge** against iTerm2's scripting
    dictionary: iterate windows → tabs → sessions, match `id`, `select` the
    session + tab. (The loop that's gnarly in raw AppleScript is clean,
    idiomatic Swift here.)
  - **Capability:** `.precise`.
- **Verify at build time** that iTerm2's `.sdef` exposes `id` + `select` as expected.

### Native-first rule (future terminals)

- ScriptingBridge / AppKit where the terminal is scriptable (iTerm2, Terminal.app).
- Shell out to the terminal's own CLI **only** where there is no Apple Events
  interface — WezTerm (`wezterm cli activate-pane`), Kitty (`kitty @ focus-window`).
  Confined to those providers; explicitly the exception, never the norm.
- `.appOnly` = activate the app (no exact tab); `.none` = banner with no click action.

## 7. Agent adapters

Each adapter maps a harness's hook event → a `pesterm` invocation. The harnesses'
hook systems are near-isomorphic (JSON, mostly on stdin), so adapters are thin.
Researched contracts (with confidence):

| Agent | Mechanism | Approval signal | "Your turn" signal | Confidence / notes |
|---|---|---|---|---|
| **Claude Code** | `Notification` hooks (settings.json) | `permission_prompt` | `idle_prompt` (true), `Stop` | High. Only harness with a real idle event. |
| **Codex** | `hooks` (stdin JSON); legacy `notify` (argv) | `PermissionRequest` | `Stop` (notify: `agent-turn-complete`) | High — verified vs Codex 0.134.0. |
| **Gemini CLI** | `hooks` (stdin JSON + `GEMINI_*` env) | `Notification`/`ToolPermission`, `BeforeTool` | `AfterAgent` | Hooks documented but not yet in published settings schema — verify installed build. Built-in OSC9 notify exists as fallback. |
| **Antigravity (`agy`)** | `hooks.json` (stdin JSON) | `PreToolUse` (decision `ask`) | `Stop` (`fullyIdle: true`) | Bleeding edge — field names provisional, known `hooks.json` path bug (issue #49). Inspect a live payload before trusting field names. |

- Only Claude Code has a true "awaiting input" event; for the others map
  **turn-complete → "your turn now."**
- Adapter job: parse payload → choose `(message, sound)` by event → pass
  `--source`. The reveal uses env (`ITERM_SESSION_ID`), not the payload.
- **Claude Code adapter ships first** (port the prototype's mapping).

## 8. App CLI interface (how adapters invoke it)

```
pesterm post \
  --title    "Claude Code" \
  --subtitle "<project dir>" \
  --message  "Permission required" \
  --sound    Hero \
  --source   claude \
  --group    "<session id>"
```

- The app posts the banner and **must stay alive** long enough to receive the
  click delegate, then runs `reveal()` in-process and exits — the same keep-alive
  pattern `terminal-notifier` uses, modeled explicitly here.
- Adapters are tiny: either shell wrappers, or an in-app `--adapter <agent>` mode
  that reads the hook JSON on stdin and translates it to the `post` form above.

## 9. Per-source branding

- Constraint: banner icon = the **posting bundle's** icon (one bundle = one icon).
- Options: (a) one neutral **pesterm** identity for all agents; (b) N thin wrapper
  bundles sharing a single binary, each with its own icon/name, so Claude / Codex /
  Gemini banners look distinct.
- **v1: option (a).** Revisit (b) if per-agent visual identity earns its keep.

## 10. Build / sign / install

- **SwiftPM** package producing the binary, packaged into a `.app` bundle
  (required for notification posting + bundle identity).
- **Signing:** ad-hoc (`codesign -s -`) for personal use; notarization out of scope.
- **Recreate-on-another-Mac:** ship source + a build script (`swift build`) so the
  target compiles locally (Xcode CLT already required) — mirrors the kit's
  no-shipped-binary philosophy.
- **Install:** place the `.app` in a tool dir; wire each agent's hook config.
  Generalize the kit's `merge-settings.py` into per-agent config writers
  (backup + atomic + idempotent).

## 11. Gotchas to preserve (don't regress)

- **Automation TCC** prompt the first time we drive iTerm2 via ScriptingBridge — one-time grant.
- **Notification permission** — the first post triggers the one-time allow prompt.
- **Banner icon = posting bundle**; can't override per-notification.
- **`ITERM_SESSION_ID` is inherited from the agent's env** — reveal reads env, never the payload.
- **The app must outlive the post** to handle the click; model the keep-alive explicitly.

## 11a. Tool approvals (blocking `PermissionRequest` hook) — NOTIFICATION-BUTTONS v1

pesterm can act as a **blocking** Claude Code `PermissionRequest` hook. When Claude is
about to prompt for tool permission, the hook fires and pesterm posts a **notification
with action buttons** — **Approve** (primary) and **Deny** (second). On
macOS (Big Sur+) these actions appear under the notification's **"Options"** affordance,
NOT as always-visible inline buttons — that's expected macOS behavior, not a bug. The
body shows the approvable action; the title/subtitle carry the tool name + short session
id so overlapping sessions are distinguishable. Tapping Approve/Deny prints the honored
decision JSON and exits 0, which Claude obeys and which SUPPRESSES the terminal
`1.Yes/2.No` menu. Because this hook owns `permission_prompt`, the `Notification` hook's
`notification_type` matcher drops that type when both are wired, so one permission never
yields two banners. **There is NO modal anywhere — a focus-stealing modal would defeat
pesterm's "pester you in place" purpose.**

### Decision contract (LOCKED)

```
allow  -> {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
deny   -> {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}
timeout/error/crash -> emit NOTHING (Claude falls back to its terminal prompt)
```

Deny is JSON `behavior:"deny"` with **exit 0** — NOT exit 2. EVERY outcome exits 0.
There is no `updatedInput`, no `always` ("don't ask again" is not in v1).

### Body click = REVEAL, not resolve

A body click on the PERMISSION notification REVEALS the iTerm2 tab (via the EXISTING
revealer) so you can read the full context in the terminal, then **RETURNS without
resolving** — the run loop stays alive (still blocking) so you can come back and tap
Approve/Deny, or let it time out. This is the key behavioral difference from the INFO
notification, which exits after reveal. Gated by `NotificationRequest.kind == .permission`.

### Mechanism

- **`kind: NotificationKind { case info, permission }`** on `NotificationRequest` gates
  the `categoryIdentifier`, the `willPresent` style, and the body-click behavior.
- **Category:** a `UNNotificationCategory` (`"pesterm.permission"`) with two
  `UNNotificationAction`s, Approve then Deny, registered via `setNotificationCategories`
  on the SAME center instance, BEFORE `add(...)`, ONLY on the permission path. Info posts
  no category (unchanged — the whole body is the reveal click target).
- **Reuses the existing keep-alive:** the permission path goes through the same
  request-building return + `app.run()` + `AppDelegate` + delegate machinery as the
  `claude` path — only the delegate branches on `kind` + the response action id.
- **120s fail-safe** armed at `post()` ENTRY, BEFORE `requestAuthorization` (the auth-gap
  fix — a never-answered first-run auth prompt still falls back). On fire: emit nothing,
  exit 0, terminal fallback — NEVER an auto-allow. Well under the 600s UN max lifetime
  and Claude's 600s hook timeout.
- **One-shot `ResolvedGate`:** an Approve/Deny tap and the 120s timer both want to
  finalize; an atomic check-and-set makes exactly one win (no double-emit, no
  late-timer-after-tap).
- **Stale cleanup:** on resolve OR timeout the delivered/pending notification for the id
  is removed.
- **Distinct group prefix `claude-perm-<guid>`** (the info stream is `claude-<guid>`) so
  the two notification streams never coalesce — the UN backend uses the groupID directly
  as the request identifier.
- **`approvableText` shows the real target:** the Bash command verbatim; for non-Bash
  tools a concise but TRUTHFUL summary of the real path/url/etc (e.g. `Write <file_path>`,
  `WebFetch <url>`) — never a target-hiding generic like `"<tool> permission"`.

### Wiring

`configure claude` (the front door, replacing `wire`) registers BOTH the `Notification`
and `PermissionRequest` hooks by default via the pure `WiringPlan.build`. The
`HookWriterRegistry` returns a deduped LIST of writers per agent; `WiringPlan`/`unwire`/
`status` iterate it (load-once / fold-each / write-once → single backup, preserved
idempotency). `--no-approvals` wires ONLY the Notification hook. A LOUD one-time consent
notice prints in the `wire` summary (and the install output) when approvals are wired.
`ClaudeHookWriter.isMine` is token-bounded so `--adapter claude` (incl.
`--adapter claude --sound Glass`) matches but `--adapter claude-permission` does not
cross-match.

### Known gaps

- **Action buttons live under the notification's "Options" affordance** on macOS
  (Big Sur+), not as always-visible inline buttons — expected macOS behavior. The
  body-click reveal + 120s timeout remain the safe fallback (still no auto-allow).
- **Subagent / Agent-Teams tool calls bypass these hooks (#23983)** — they still use
  Claude's normal terminal prompts. **Silence is NOT safety.**
- **Interactive-only:** `PermissionRequest` does not fire under headless `claude -p`
  (only `PreToolUse`); approvals do nothing there.
- **Long commands truncate in the banner body** — accepted; the body-click reveal is the
  "see more" path.

### Deferred to v2 (do NOT build in v1)

A "tap to see more" expanded view (beyond the body-click reveal) and an **Always /
don't-ask-again** grant (`permission_suggestions`) are possible future adds — NOT v1.
Any "Always" reintroduction needs a spike proving the exact apply schema. An earlier
dynamic-by-fit / modal escalation idea is shelved: v1 accepts banner truncation. If a
future spike revisits escalation, recall that "fits the banner" proves VISIBILITY not
SAFETY — a short dangerous command must not get a frictionless one-tap, so any escalation
must be dangerous-token driven, not length driven.

## 12. Roadmap

- **Phase 0** — this spec.
- **Phase 1** — Swift core + UserNotifications backend + iTerm2 revealer
  (ScriptingBridge) + Claude Code adapter. Parity with the bash prototype, zero external deps.
  (Shipped first on the older NSUserNotification API, then migrated to UNUserNotification.)
- **Phase 2** — build/sign/install tooling; per-agent settings merge.
- **Phase 3** — Codex, Gemini, Antigravity adapters.
- **Phase 4** — more terminals: Terminal.app (ScriptingBridge), WezTerm/Kitty
  (their CLIs); capability tiers + graceful degradation.
- **Phase 5 (maybe)** — per-source branding bundles; tmux (two-level reveal).

## 13. Open questions

- **Notification API:** ~~start on NSUserNotification vs jump to UNUserNotification?~~
  RESOLVED — shipped on NS first to dodge the auth prompt, then migrated to
  UNUserNotification once a spike proved it delivers fine from our ad-hoc-signed bundle.
  The `NotificationBackend` protocol made it a one-file swap. NS is gone.
- **SwiftPM-only vs an Xcode project** for the `.app`/bundle resources?
- **Per-source branding** in v1 or defer? (Leaning defer.)
- **Cleanest keep-alive-for-click** pattern (run loop + timeout).
- **tmux** — defer (env stripping + two-level focus is its own problem).

## Reference

- Prototype (bash): https://github.com/luinstra/claude-notify-kit — the working
  proof-of-concept this replaces; its README documents the macOS gotchas in detail.
