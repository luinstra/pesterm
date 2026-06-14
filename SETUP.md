# pesterm — Setup & one-time grants

This documents the install flow and the human-interactive steps that pesterm cannot
perform for you.

## Install

```sh
scripts/install.sh
```

The installer builds the bundle, places it under `$PREFIX/share/pesterm`
(default `PREFIX=$HOME/.local`, override with `PESTERM_PREFIX`), writes the
`$PREFIX/bin/pesterm` CLI entry, verifies the bundle identity through it, and then
**hands off to the guided `pesterm configure` flow** — which wires the Claude Code hooks
for you (no manual `~/.claude/settings.json` editing) and reports/links the grants below.
At a terminal it's interactive; with no TTY (`curl | bash` / CI) it applies defaults. See
[README.md](./README.md#install) for the full step list.

After installing, **restart Claude Code** so it reloads `~/.claude/settings.json`,
then verify with:

```sh
pesterm status
```

## One-time human setup

**Allow notifications.** The FIRST time pesterm posts, macOS shows a one-time
**"pesterm wants to send you notifications"** prompt (the UserNotifications authorization
grant). Click **Allow**. If you deny it, banners are suppressed until you re-enable pesterm
under **System Settings → Notifications → pesterm**.

**Automation grant: not needed normally, REQUIRED under tmux.** The jump-to-tab reveal
drives iTerm via Apple Events. Normally pesterm runs as a descendant of iTerm (spawned by
the hook), so the reveal is *self-automation* — macOS allows it with no grant. The bundle
carries `NSAppleEventsUsageDescription` for the rare config where a grant is needed.

Inside **tmux**, that's exactly such a config: tmux's server is a background daemon (its
parent is launchd, not iTerm), so a hook fired inside tmux is NOT an iTerm descendant.
Self-automation no longer covers it, and the reveal needs an Automation grant to control
iTerm. macOS shows a one-time **"pesterm wants to control iTerm2"** prompt the first time
you click a notification from a tmux session — click **OK**. Symptom if it's missing/denied:
clicking fronts iTerm but does NOT switch to the right tab/pane (the tmux lookup succeeds,
but the Apple Event that selects the iTerm session is blocked). Re-enable under **System
Settings → Privacy & Security → Automation → pesterm → iTerm**.

(All other pesterm features — notifications, sounds, `--timeout`, approve/deny — work under
tmux with no extra grant; only the click-to-jump reveal needs it.)

## Claude Code hook wiring (done for you by `configure`)

`scripts/install.sh` hands off to the equivalent of:

```sh
pesterm configure claude --command-path "$PREFIX/bin/pesterm"
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

To (re)configure or unwire by hand, or to point at a different settings file:

```sh
pesterm configure claude                          # guided (prompts for approvals + sound)
pesterm configure claude --yes                     # non-interactive: apply defaults
pesterm unwire claude --yes                         # removes ONLY pesterm's entry
```

`configure` never hangs and never refuses: at a terminal it prompts; with no TTY (or
`--yes`) it applies defaults. `unwire` without `--yes` in a non-TTY prints the `--yes`
re-run hint and exits without touching anything. A malformed settings file is refused
(non-zero exit, file untouched). A backup (`settings.json.bak-YYYYMMDD-HHMMSS`) is
written only when content actually changes.

## Tool approvals (Approve/Deny from a notification) — ON by default

`pesterm configure claude` registers TWO hooks: the `Notification` hook above AND a blocking
`PermissionRequest` tool-approval hook. When Claude is about to prompt for tool
permission, pesterm posts a **notification with Approve / Deny actions**
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
- **Interactive tools are NOT mediated.** Tools whose own terminal UI is the point —
  `AskUserQuestion`, `ExitPlanMode` — never produce an Approve/Deny banner (approving a
  question just to then answer it is absurd). pesterm emits nothing and Claude handles
  them natively. This is a denylist: every other tool, and any unknown tool, is mediated
  by default.
- **Disable approvals:** wire only the Notification hook with `--no-approvals`:

  ```sh
  pesterm configure claude --yes --no-approvals
  ```

  When approvals are wired, `configure` prints a LOUD one-time consent notice telling you
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

The per-event defaults above can be overridden. Pass `--sound <name>` when configuring to
bake the override into the hook command:

```sh
pesterm configure claude --sound Glass     # → '…/pesterm' --adapter claude --sound Glass
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

## Future work

- Homebrew formula.
- Phase 3 adapters: Codex, Gemini CLI, Antigravity (additive `HookWriter`
  conformances — no merger or CLI changes).
- Phase 5: real signing + notarization.
