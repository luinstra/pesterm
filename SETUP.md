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

2. **Notification style = Alerts.** Banners auto-dismiss and kill the click, so the
   reveal never fires. Open **System Settings → Notifications → pesterm** and set the
   style to **Alerts** (this is separate from the allow-prompt above — granting
   notifications doesn't pick the style for you).

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

which idempotently merges this single matcher-less entry into
`~/.claude/settings.json`, preserving every unrelated hook:

```json
{
  "hooks": {
    "Notification": [
      {
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
a bare symlink would NOT). No per-event `matcher` entries are needed — the adapter
branches on `notification_type` itself (`permission_prompt` / `idle_prompt` /
`elicitation_dialog`; `auth_success` and any unknown type are suppressed for prototype
parity).

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

## Verify

```sh
pesterm status
```

reports the bundle install path, the CLI entry + on-`PATH` state, the wired state for
each supported agent (with the command path and a **stale** flag if that path no
longer exists), the running process's bundle identity, and the manual-grant reminders.

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

1. **Alerts style is mandatory** (grant #2 above) — banners kill the click.
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
