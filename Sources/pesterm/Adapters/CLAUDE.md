# Adapters — Claude Code Guidance

> **Context:** Translate Claude Code hook JSON (stdin) into a `NotificationRequest`, and a permission decision back into the JSON Claude expects.
> **Parent Guide:** [Project Root](../../../CLAUDE.md)
> **See Also:** [Permission](../Permission/CLAUDE.md) · [Wiring](../Wiring/CLAUDE.md)

## Quick Reference

Two inbound hook shapes, dispatched by `--adapter`:

- **`claude`** → `ClaudeAdapter` — the **Notification** hook. Maps `notification_type` to a
  (message, sound) and posts a `.info` notification (click = reveal, then exit).
- **`claude-permission`** → `ClaudePermissionAdapter` — the **PermissionRequest** hook.
  Renders the tool's real action and posts a `.permission` notification with Approve/Deny.

Both adapters conform to **`AgentAdapter`**; `AdapterRegistry.adapter(for:)` looks one up by
its `--adapter` value (unknown → caller exits `2`). Each adapter's `outcome(stdin:…)` returns
`.post(request)` or `.suppress(reason)` — purely; main.swift owns the stderr write + exit.
Outbound, `PermissionDecision.outputJSON(for:)` produces the decision Claude reads from stdout.

## Structure

```
Adapters/
├── AgentAdapter.swift             # protocol: adapterValue + kind + outcome(stdin:) → AdapterOutcome
├── AdapterRegistry.swift          # --adapter value → AgentAdapter.Type (mirrors RevealerRegistry)
├── AgentSource.swift              # which agent; owns the group-prefix vocabulary
├── ClaudeAdapter.swift            # "claude": Notification hook → .info request
├── ClaudePermissionAdapter.swift  # "claude-permission": PermissionRequest hook → .permission request
└── PermissionDecision.swift       # decision enum → the locked stdout JSON
```

### Adding an agent is additive

A 2nd agent (e.g. Codex) = a new `AgentAdapter` conformance + one line in `AdapterRegistry`,
plus a case in `AgentSource` (which derives the group prefix, so the agent-name string lives
in one place). `main.swift` dispatches through the registry and never names a concrete
adapter. NOTE: the *decision-return* JSON is still Claude-specific (`PermissionDecision`) —
that moves behind the protocol when the permission flow is reworked (see Permission guide).

## Key Patterns

### Everything here is PURE and unit-tested

Parsing and rendering take `Data`/structs in and return values out — no posting, no AppKit,
no I/O. That's why `ClaudeAdapterTests` / `ClaudePermissionAdapterTests` can exercise every
branch headlessly. Keep new logic pure; do the side effects in the backend.

### The decision JSON is LOCKED

`PermissionDecision.outputJSON` emits exactly this (allow shown; deny swaps `behavior`):

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

Don't reshape it casually — Claude Code parses it verbatim. (If approvals break after a
Claude Code upgrade, suspect the *consumer* honoring this late, not this string. See the
Permission guide's investigation note.)

### Mediation is a DENYLIST, not an allowlist

`shouldMediate(_:)` returns `true` for every tool **except** the interactive/meta ones in
`unmediatedTools` (`AskUserQuestion`, `ExitPlanMode`) — those own their terminal UI, so
mediating them is absurd. Crucially, **nil/empty/unknown tool names mediate by default**:
a new side-effecting tool is never silently un-gated. "Silence is not safety."

### Render the REAL target, never a generic

`approvableText` shows the actual command/path/url (`Bash` → full command string;
`Write <file_path>`, `WebFetch <url>`). Never a target-hiding `"<tool> permission"`. The OS
truncates the banner; the full text is reachable via the body-click reveal.

### Reveal target: env, not payload

`buildRequest(... iTermSessionId:)` takes the iTerm2 GUID from `ITERM_SESSION_ID` (the env,
resolved in `main.swift`) purely for the coalescing group. `payload.session_id` is only the
short human label in the title/subtitle. This mirrors the root invariant — don't cross them.

### Distinct group prefixes

`ClaudeAdapter.groupPrefix` is `"claude-"`; `ClaudePermissionAdapter.groupPrefix` is
`"claude-perm-"`. The backend uses `groupID` as the notification identifier, so distinct
prefixes keep info and permission streams from coalescing over each other.

## Common Mistakes

❌ **Mapping an unknown `notification_type`/tool to a default banner or auto-allow.**
```swift
// Bad: invents output for an event the prototype never notified on / un-gates a new tool
default: return ("Something happened", "Pop")
```

✅ **Suppress and exit 0 for unknowns on the info path; mediate-by-default on the permission path.**
```swift
default: return nil          // ClaudeAdapter: caller logs + exit(0)
// shouldMediate(nil) == true // ClaudePermissionAdapter: post Approve/Deny by default
```

❌ **Hiding the target behind the tool name.**
```swift
return "\(tool) permission"   // user can't tell what they're approving
```

✅ **Name the real target.**
```swift
return cmd                    // the actual Bash command, Write path, WebFetch url, …
```

## Working Here Checklist

- [ ] New logic is a pure function with a test in `Tests/pestermTests/`
- [ ] Unknown/missing inputs degrade safely (info → suppress+exit0; permission → mediate)
- [ ] Reveal/group uses the env session id, human label uses `payload.session_id`
- [ ] Didn't touch the locked decision JSON shape without a deliberate reason

## Related Guides

- [Permission](../Permission/CLAUDE.md) — what happens after a `.permission` request is built
- [Wiring](../Wiring/CLAUDE.md) — how the `--adapter`/`--sound` hook commands get written
