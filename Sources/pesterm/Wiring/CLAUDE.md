# Wiring — Claude Code Guidance

> **Context:** Surgically edit `~/.claude/settings.json` to add/remove pesterm's hooks — **without clobbering** anything the user owns.
> **Parent Guide:** [Project Root](../../../CLAUDE.md)
> **See Also:** [`ConfigureCommand`](../CLI/ConfigureCommand.swift) · [Adapters](../Adapters/CLAUDE.md)

## Quick Reference

`WiringPlan.build(...)` is the **single source of truth** for what pesterm writes into
settings. `ConfigureCommand` and the wiring tests both call it, so there's no second
hand-rolled loop to drift. The actual JSON edit is a pure, refuse-to-clobber merge in
`SettingsMerger`.

## Structure

```
Wiring/
├── WiringPlan.swift               # PURE: fold an agent's hooks into settings (the semantics)
├── SettingsMerger.swift           # PURE: upsert/remove one hook entry; atomic write + backup
├── HookWriter.swift               # protocol: hookEvent, isMine(_:), makeEntry(command:sound:)
├── HookWriterRegistry.swift       # agent → its hook writers
├── ClaudeHookWriter.swift         # the Notification hook entry + its matcher variants
├── PermissionRequestHookWriter.swift  # the blocking approval hook entry
└── ExecutablePath.swift           # resolve the absolute binary path baked into commands
```

## Key Patterns

### `WiringPlan` owns the approvals semantics

- `approvals == true` → upsert **both** hooks. The Notification matcher **omits**
  `permission_prompt` (the PermissionRequest hook owns that event) so one permission yields
  **one** banner, not two.
- `approvals == false` → upsert the Notification hook with a matcher that **includes**
  `permission_prompt` (it now owns the event) **and actively REMOVE** any existing
  PermissionRequest entry. Disabling approvals truly disables them, not just skips writing.

Approvals only wire if the agent actually *has* a `PermissionRequestHookWriter`.

### `SettingsMerger` refuses to clobber

Preserve everything pesterm doesn't own. A **missing** `hooks` key or event key is fine
(it's created). A **present-but-wrong-type** `hooks` (not an object) or event (not an array)
**throws** rather than overwriting. Malformed JSON in the file → throw and touch nothing.

`isMine(_:)` identifies pesterm's own entries so an upsert replaces *ours* and leaves every
other hook untouched.

### Write discipline

- Deterministic serialize: **sorted keys**, pretty-printed, trailing newline — so the
  proposed-vs-current comparison for idempotency is meaningful.
- **Backup only on an actual content change** (`<path>.bak-YYYYMMDD-HHMMSS`, de-duped).
- **Atomic write** via a **same-directory** temp file + rename — `NSTemporaryDirectory()`
  can be on a different mount, which would break the cross-device rename.
- Idempotency lives at the caller: compare serialized proposed vs current, **skip `write`
  on a no-op** (no needless backup churn).

## Common Mistakes

❌ **Hand-rolling the upsert loop in a new command.**
✅ **Call `WiringPlan.build(...)`** — one source of truth, already tested.

❌ **Overwriting `hooks` when it's an unexpected shape.**
```swift
settings["hooks"] = myHooks   // clobbers a user's hand-edited config
```
✅ **Let `SettingsMerger` throw and bail** so the user fixes it manually.

❌ **Wiring both hooks with overlapping matchers** → two banners per permission.
✅ **Let `WiringPlan` pick the matcher variant** (`handledNotificationTypesNoPermission`
   when approvals are on).

❌ **Writing through a temp file in `NSTemporaryDirectory()`.**
✅ **Temp file beside the target**, then atomic rename.

## Working Here Checklist

- [ ] New wiring behavior goes through `WiringPlan.build`, not a fresh loop
- [ ] Refusal posture preserved: present-but-wrong-type throws; missing is created
- [ ] Backups only on real change; writes atomic + same-directory temp
- [ ] Matcher ownership of `permission_prompt` stays mutually exclusive
- [ ] Added/changed behavior covered in `WirePairTests` / `SettingsMergerTests`

## Related Guides

- [Adapters](../Adapters/CLAUDE.md) — the `--adapter`/`--sound` commands these hooks invoke
- [Permission](../Permission/CLAUDE.md) — what the PermissionRequest hook actually does
