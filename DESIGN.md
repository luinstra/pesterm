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
4. **Banners auto-dismiss; Alerts persist** — the click needs Alerts style. →
   Still a user setting; documented, unavoidable.

## 5. Architecture

Two abstraction axes (**agents** = how we're triggered, **terminals** = how we
reveal) plus a swappable **notification backend**:

```
[agent harness hook] --JSON (stdin/argv)--> [agent adapter] --CLI args--> [pesterm core]
                                                                                |
                                              +---------------------------------+--------------------+
                                              |                                                      |
                                     [NotificationBackend]                                  [TerminalRevealer]
                                  NSUserNotification (v1)                          iTerm2 via ScriptingBridge + AppKit (v1)
                                  UNUserNotification (later)                       other terminals later, behind the protocol
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
- **Notification permission** + set the app's notification style to **Alerts**
  (Banners auto-dismiss and kill the click).
- **Banner icon = posting bundle**; can't override per-notification.
- **`ITERM_SESSION_ID` is inherited from the agent's env** — reveal reads env, never the payload.
- **The app must outlive the post** to handle the click; model the keep-alive explicitly.

## 12. Roadmap

- **Phase 0** — this spec.
- **Phase 1** — Swift core + NSUserNotification backend + iTerm2 revealer
  (ScriptingBridge) + Claude Code adapter. Parity with the bash prototype, zero external deps.
- **Phase 2** — build/sign/install tooling; per-agent settings merge.
- **Phase 3** — Codex, Gemini, Antigravity adapters.
- **Phase 4** — more terminals: Terminal.app (ScriptingBridge), WezTerm/Kitty
  (their CLIs); capability tiers + graceful degradation.
- **Phase 5 (maybe)** — UNUserNotification migration; per-source branding bundles;
  tmux (two-level reveal).

## 13. Open questions

- **Notification API:** start on NSUserNotification (friction-free from a CLI-launched
  bundle) vs jump straight to UNUserNotification (modern, but stricter signing/auth)?
  Lean: start NS, keep it behind `NotificationBackend` for a contained later swap.
- **SwiftPM-only vs an Xcode project** for the `.app`/bundle resources?
- **Per-source branding** in v1 or defer? (Leaning defer.)
- **Cleanest keep-alive-for-click** pattern (run loop + timeout).
- **tmux** — defer (env stripping + two-level focus is its own problem).

## Reference

- Prototype (bash): https://github.com/luinstra/claude-notify-kit — the working
  proof-of-concept this replaces; its README documents the macOS gotchas in detail.
