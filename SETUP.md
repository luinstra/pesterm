# pesterm — Setup & one-time grants (Phase 1)

This documents the human-interactive steps that pesterm cannot perform for you, plus
the supported Claude Code hook wiring. Build the app first:

```sh
scripts/build-app.sh        # produces ./pesterm.app (ad-hoc signed)
```

Then move `pesterm.app` to a stable location (e.g. `~/Applications/pesterm.app`) so
its bundle identity stays put.

## One-time human setup (REQUIRED — pesterm cannot do these for you)

1. **Notification style = Alerts.** Banners auto-dismiss and kill the click, so the
   reveal never fires. After the first post registers pesterm, open
   **System Settings -> Notifications -> pesterm** and set the style to **Alerts**.
   (There is no `requestAuthorization` call in the NSUserNotification path — the
   signed bundle self-registers on its first post.)

2. **Automation (TCC) grant for iTerm2.** The FIRST time pesterm drives iTerm2 via
   ScriptingBridge (i.e. the first time you click a notification and it reveals), macOS
   shows a one-time **"pesterm wants to control iTerm2"** prompt. Click **OK**. This
   prompt only appears because the bundle carries `NSAppleEventsUsageDescription`. If
   you deny it, reveal will be blocked until you re-enable pesterm under
   **System Settings -> Privacy & Security -> Automation**.

## Claude Code hook wiring (supported invocation: the INNER binary)

Call the inner binary directly (NOT `open pesterm.app --args`). It posts under the
bundle identity because the binary lives inside the signed bundle.

Add to `~/.claude/settings.json` (adjust the path to where you placed the app):

```json
{
  "hooks": {
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/Applications/pesterm.app/Contents/MacOS/pesterm --adapter claude"
          }
        ]
      }
    ]
  }
}
```

No per-event `matcher` entries are needed — the adapter branches on
`notification_type` itself (`permission_prompt` / `idle_prompt` / `elicitation_dialog`;
`auth_success` and any unknown type are suppressed for prototype parity).

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
