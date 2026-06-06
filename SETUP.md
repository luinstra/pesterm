# pesterm — Setup & one-time grants

This documents the install flow and the human-interactive steps that pesterm cannot
perform for you.

## Install

```sh
scripts/install.sh
```

The installer builds the bundle, places it under `$PREFIX/share/pesterm`
(default `PREFIX=$HOME/.local`, override with `PESTERM_PREFIX`), writes the
`$PREFIX/bin/pesterm` CLI entry, verifies the bundle identity through it, and
**self-wires the Claude Code hook for you** — no manual `~/.claude/settings.json`
editing required. See [README.md](./README.md#install) for the full step list.

After installing, **restart Claude Code** so it reloads `~/.claude/settings.json`,
then verify with:

```sh
pesterm status
```

## One-time human setup (REQUIRED — pesterm cannot do these for you)

1. **Allow notifications.** The FIRST time pesterm posts, macOS shows a one-time
   **"pesterm wants to send you notifications"** prompt (the UserNotifications
   authorization grant). Click **Allow**. If you deny it, banners are suppressed until
   you re-enable pesterm under **System Settings → Notifications → pesterm**.

2. **Alert Style = Persistent.** A temporary notification auto-dismisses and kills the
   click, so the reveal never fires. Open **System Settings → Notifications → pesterm**
   and set **Alert Style** to **Persistent** (macOS renamed the old "Banners / Alerts"
   choice to "Temporary / Persistent"; this is separate from the allow-prompt above —
   granting notifications doesn't pick the style for you). **A Persistent alert style is
   also LOAD-BEARING for the tool-approval Approve/Deny actions** (see below): on macOS
   (Big Sur+) those actions appear under the notification's **"Options"** affordance, not
   as always-visible inline buttons — that's expected macOS behavior. `pesterm status`
   reminds you to set it.

3. **Automation (TCC) grant for iTerm2.** The FIRST time pesterm drives iTerm2 via
   ScriptingBridge (i.e. the first time you click a notification and it reveals), macOS
   shows a one-time **"pesterm wants to control iTerm2"** prompt. Click **OK**. This
   prompt only appears because the bundle carries `NSAppleEventsUsageDescription`. If
   you deny it, reveal will be blocked until you re-enable pesterm under
   **System Settings → Privacy & Security → Automation**.

## Claude Code hook wiring (done for you by the installer)

`scripts/install.sh` runs the equivalent of:

```sh
pesterm wire claude --yes --command-path "$PREFIX/bin/pesterm"
```

which idempotently merges this single entry into `~/.claude/settings.json`, preserving
every unrelated hook:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt|permission_prompt|elicitation_dialog",
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.local/bin/pesterm --adapter claude"
          }
        ]
      }
    ]
  }
}
```

The hook command is the stable `$PREFIX/bin/pesterm` path (a `bash` `exec` wrapper
that runs the inner bundle binary, so notifications post under the bundle identity —
a bare symlink would NOT). The `Notification` matcher filters on `notification_type`
(`|` = OR), so pesterm only fires on the types it handles (`idle_prompt` /
`permission_prompt` / `elicitation_dialog`; `auth_success` and any unknown type are
suppressed for prototype parity). When tool approvals are wired (see below),
`permission_prompt` is OMITTED from this matcher — the `PermissionRequest` approval hook
owns that event, so you never get two banners for one permission:

```json
{ "matcher": "idle_prompt|elicitation_dialog",
  "hooks": [{ "type": "command", "command": "…/pesterm --adapter claude" }] }
```

To wire/unwire by hand, or to point at a different settings file:

```sh
pesterm wire claude                              # interactive confirm
pesterm wire claude --yes                         # no prompt
pesterm wire claude --settings /path/to/settings.json
pesterm unwire claude --yes                        # removes ONLY pesterm's entry
```

In a non-TTY (e.g. CI) without `--yes`, `wire`/`unwire` print the `--yes` re-run hint
and exit without touching anything — they never hang. A malformed settings file is
refused (non-zero exit, file untouched). A backup
(`settings.json.bak-YYYYMMDD-HHMMSS`) is written only when content actually changes.

## Tool approvals (Approve/Deny from a notification) — ON by default

`pesterm wire claude` registers TWO hooks: the `Notification` hook above AND a blocking
`PermissionRequest` tool-approval hook. When Claude is about to prompt for tool
permission, pesterm posts a **Persistent-style notification with Approve / Deny actions**
(on macOS Big Sur+ these appear under the notification's **"Options"** affordance, not as
always-visible inline buttons). The body shows the action (the Bash command, or the real
path/url for other tools); the title/subtitle carry the tool name + short session id.
Tapping **Approve** allows the tool, tapping **Deny** denies it — and the terminal
`1.Yes/2.No` menu is suppressed. Because approvals own `permission_prompt`, the
`Notification` hook's matcher drops that type when both are wired (no double banner).

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          { "type": "command", "command": "$HOME/.local/bin/pesterm --adapter claude-permission" }
        ]
      }
    ]
  }
}
```

- **Body click reveals WITHOUT deciding.** Click the notification BODY (not a button) to
  reveal the iTerm2 tab and read the full context in the terminal; the notification
  PERSISTS, so you can then tap Approve/Deny or let it time out. A body click never
  resolves the request.
- **120s timeout / error / first-run auth gap → terminal fallback, NEVER auto-allow.** If
  you don't respond within 120 seconds (or pesterm errors, or the first-run notification
  auth prompt sits unanswered), pesterm emits nothing and Claude falls back to its own
  terminal prompt. Silence is never an approval.
- **Disable approvals:** wire only the Notification hook with `--no-approvals`:

  ```sh
  pesterm wire claude --yes --no-approvals
  ```

  When approvals are wired, `wire` prints a LOUD one-time consent notice telling you
  they're on and how to disable them.

### ⚠ Subagent warning — pesterm does NOT mediate subagent tool calls

pesterm does NOT mediate **subagent / Agent-Teams** tool calls — those still use Claude's
normal terminal prompts (upstream #23983). **Silence is NOT safety:** if you don't see a
pesterm Approve/Deny notification for a tool call, it does not mean the call was blocked —
it may be a subagent prompting in the terminal instead. This matters because approvals are
on by default.

### Interactive-only

The `PermissionRequest` hook fires only in an interactive Claude Code session. Headless
`claude -p "…"` does NOT trigger it (only `PreToolUse`), so approvals do nothing there.

## Verify

```sh
pesterm status
```

reports the bundle install path, the CLI entry + on-`PATH` state, the wired state for
each supported agent — listing `claude` once with a per-event breakdown (`Notification`
and `PermissionRequest`), each with its command path and a **stale** flag if that path no
longer exists — the running process's bundle identity, and the manual-grant reminders.

## Event mapping (parity with the bash prototype)

| notification_type   | message               | sound |
|---------------------|-----------------------|-------|
| `idle_prompt`       | "Awaiting your input" | Morse |
| `permission_prompt` | "Permission required" | Hero  |
| `elicitation_dialog`| "Question for you"    | Pop   |
| `auth_success`      | (suppressed)          | —     |
| unknown / missing   | (suppressed)          | —     |

Title is always `Claude Code`; subtitle is the basename of `cwd`; the coalescing group
is `claude-<iTerm2 session id>` where the session id is the LAST colon-component of the
inherited `ITERM_SESSION_ID` (never the agent payload).

## Sounds (`--sound`, `pesterm sounds`, `pesterm sample`)

The per-event defaults above can be overridden. Pass `--sound <name>` when wiring to
bake the override into the hook command:

```sh
pesterm wire claude --sound Glass     # → '…/pesterm' --adapter claude --sound Glass
```

When present, `--sound` replaces the default sound for whatever events that hook entry
handles; when absent, the per-event defaults stand. For different sounds per event,
hand-wire a separate matcher entry per event, each with its own `--sound`.

Sound names resolve from the standard NSSound directories — `/System/Library/Sounds`,
`~/Library/Sounds`, `/Library/Sounds` — so any custom sound dropped into
`~/Library/Sounds` (e.g. `notification.aiff`, `codex-notification.aiff`) works as a
`--sound` value. Discover and audition names:

```sh
pesterm sounds              # authoritative list of valid --sound names (system + customs)
pesterm sample Glass        # play a sound to hear it; errors if the name is unknown
```

Note: the newer macOS Tahoe alert sounds (Boop, etc.) are NOT name-addressable here —
only the classic `/System/Library/Sounds` set and custom-dir sounds resolve by name.

## Known wrinkles

1. **Persistent Alert Style is mandatory** (grant #2 above) — a temporary alert kills the click.
2. **One-time iTerm2 control grant** (grant #3 above).
3. **TCC re-prompt on rebuild.** Ad-hoc signatures key off the bundle cdhash, so a
   rebuild + reinstall changes the hash and re-triggers the "control iTerm2" prompt.
   Expected until Phase 5 (real Developer ID signing + notarization) lands. The
   installer always signs LAST and runs `codesign --verify --deep --strict`, so a
   broken/partial signature never ships to confuse TCC further.

## Future work

- Homebrew formula.
- Phase 3 adapters: Codex, Gemini CLI, Antigravity (additive `HookWriter`
  conformances — no merger or CLI changes).
- Phase 5: real signing + notarization.
