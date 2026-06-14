# pesterm

**Your CLI agent pesters you back to the right terminal tab.**

pesterm is a native macOS notifier for terminal-based AI coding agents. When your agent
needs you — it wants permission, has a question, or just finished a turn — pesterm posts a
notification. Click it and you land on the **exact iTerm2 tab** the agent is running in,
across windows and split panes.

For **Claude Code** it does one more thing: **approve or deny tool permissions straight
from the notification**, without switching back to the terminal.

Supported today: **Claude Code**. Codex, Gemini CLI, and Antigravity are planned (each is
an additive adapter — see [DESIGN.md](./DESIGN.md)).

## Requirements

- macOS 11 (Big Sur) or later
- iTerm2 (the jump-to-tab reveal drives iTerm2)
- A Swift toolchain to build (Xcode or the Swift command-line tools)

## Install

```sh
scripts/install.sh
```

No sudo. The installer builds and ad-hoc-signs `pesterm.app`, installs it under `~/.local`
(override with `PESTERM_PREFIX`), puts a `pesterm` command on your `PATH`, then hands off
to **`pesterm configure`** — the guided setup that wires the Claude Code hooks, checks your
macOS grants, and links you to anything still needed. Re-running is safe (idempotent).

If `~/.local/bin` isn't on your `PATH`, the installer prints the `export PATH=…` line to
add to your shell profile.

### One-time macOS grants

**Allow notifications** for pesterm — macOS prompts the first time pesterm posts; click
**Allow**. Normally that's the only grant needed: the jump-to-tab reveal drives iTerm from
an iTerm-descendant process (self-automation), so it needs no Automation grant.

**Using tmux? One extra grant.** Inside tmux, pesterm runs under the tmux *server* (a
background daemon), not as a descendant of iTerm — so self-automation doesn't apply and the
reveal needs permission to control iTerm. macOS shows a one-time **"pesterm wants to control
iTerm2"** prompt the first time you click a notification from a tmux session — click **OK**.
If you dismissed it, the tab/pane won't switch (iTerm just comes to the front); enable it
under **System Settings → Privacy & Security → Automation → pesterm → iTerm**.

Detail in **[SETUP.md](./SETUP.md)**.

## Usage

### `pesterm configure`

The front door. Run it any time to change your setup — it re-reads your choices and grant
state, so it's the one command to remember.

```sh
pesterm configure                 # guided: tool approvals, sound, grant check
pesterm configure --yes           # non-interactive: apply defaults (CI / curl | bash)
pesterm configure --no-approvals  # notifications only, no tool approvals
pesterm configure --sound Glass   # use Glass instead of the per-event default sounds
pesterm configure --force         # re-run setup even if already configured (overwrites it)
```

**Reinstall-safe.** If pesterm is already configured, `configure` (and the installer) leave
your existing hooks **untouched** — no prompts, no overwrite — so hand-edits like per-event
sounds/timeouts survive a reinstall. It just reports what's wired and checks grants. Pass
`--force` (or an explicit `--sound` / `--no-approvals`) to deliberately re-run setup.

### Notifications

When Claude needs you, you get a banner — click it to jump to the tab.

| Event | Meaning | Default sound |
|-------|---------|---------------|
| `idle_prompt` | Awaiting your input | Morse |
| `permission_prompt` | Permission required | Hero |
| `elicitation_dialog` | A question for you | Pop |

### Tool approvals (Claude Code)

**On by default.** When Claude is about to ask for tool permission, pesterm posts a
**notification with Approve / Deny actions** showing the command (or the real
path/URL for non-Bash tools). Tap **Approve** or **Deny** — the terminal `1.Yes/2.No` menu
is suppressed. Click the notification **body** (not a button) to reveal the tab and read
full context *without* deciding. No response within 120s (tunable — see
[Notification lifetime](#notification-lifetime---timeout)), or any error, falls back to
Claude's own terminal prompt and **never auto-allows**.

Caveats worth knowing:

- **Interactive-only** — doesn't fire under headless `claude -p`.
- **Subagent tool calls aren't mediated** — those still prompt in the terminal
  ([#23983](https://github.com/anthropics/claude-code/issues/23983)). No banner ≠ blocked.
- **Interactive tools aren't mediated** — `AskUserQuestion` and `ExitPlanMode` use Claude's
  native prompt (approving a question just to then answer it makes no sense).

Disable with `pesterm configure --no-approvals`.

### Sounds

Every event has a default sound (the table above). To override it you pass a sound **name**
— and the way to find valid names is:

```sh
pesterm sounds          # list every valid --sound name on YOUR machine
pesterm sample Glass    # play one to audition it before committing
```

`pesterm sounds` is the source of truth. Names come from the standard macOS sound folders —
`/System/Library/Sounds` (the classic set: `Glass`, `Hero`, `Morse`, `Ping`, `Pop`,
`Sosumi`, `Submarine`, …) and `~/Library/Sounds`. Want a custom sound? Drop a sound file
(`.aiff`, `.wav`, `.caf`, `.m4a`, …) into `~/Library/Sounds` and use its filename (no
extension) as the `--sound` name.

**Silence:** `--sound none` (also `off` / `silent` / `mute`) posts with **no sound** — for
the whole setup (`pesterm configure --sound none`) or per event by putting it on a single
matcher in the `settings.json` below (e.g. silence idle pings, keep approvals audible).

> Heads-up: the newer macOS Tahoe alert sounds (Boop, etc.) aren't name-addressable — only
> the classic system set and your custom-folder sounds resolve by name.

### Notification lifetime (`--timeout`)

An ignored notification doesn't linger forever, and its background process exits the moment
you dismiss the notification — or after a cap if you never touch it:

| Notification | Default cap | What happens at the cap |
|--------------|-------------|-------------------------|
| Info (idle / question) | **180s** | banner auto-clears, process exits |
| Permission (Approve / Deny) | **120s** | falls back to Claude's terminal prompt, process exits |

Override either with **`--timeout <seconds>`** on the hook command (see below). Click or
dismiss still exits immediately; the cap is just the backstop. Permission timeouts are
clamped under Claude's ~600s hook limit, and any value floors at 5s.

### Per-event sounds & timeouts (`settings.json`)

`pesterm configure --sound X` sets **one** sound for everything. For a **different sound per
event**, or to set **`--timeout`**, edit the hook commands in `~/.claude/settings.json`
directly — just append the flags to the `command` string. Here's a full example: a distinct
sound per event, a longer idle timeout, and a snappier approval window.

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          { "type": "command", "command": "pesterm --adapter claude-permission --timeout 90" }
        ]
      }
    ],
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          { "type": "command", "command": "pesterm --adapter claude --sound Morse --timeout 300" }
        ]
      },
      {
        "matcher": "elicitation_dialog",
        "hooks": [
          { "type": "command", "command": "pesterm --adapter claude --sound Pop" }
        ]
      }
    ]
  }
}
```

- The **`PermissionRequest`** hook drives tool approvals. It owns the `permission_prompt`
  event, which is why that type is left out of the `Notification` matcher.
- Split the **`Notification`** matcher into one entry per `notification_type` to give each
  its own `--sound` / `--timeout`. Valid types: `idle_prompt`, `elicitation_dialog` — plus
  `permission_prompt` only if you ran `pesterm configure --no-approvals`.
- Both flags are optional. Omit `--sound` to keep the per-event default; omit `--timeout` to
  keep the standard cap (180s info / 120s permission).

Run `pesterm status` to see what's currently wired, and `pesterm configure` to re-wire the
basics from scratch.

### All commands

| Command | What it does |
|---------|--------------|
| `pesterm configure [agent]` | Guided setup (the front door): tool approvals, sound, grant check + deep-links. `--yes` applies defaults non-interactively. |
| `pesterm status` | Report install path, `PATH` state, per-agent wired state, running bundle identity, and the manual grants. |
| `pesterm unwire <agent>` | Remove **only** pesterm's hook entries; never touches unrelated hooks. |
| `pesterm sounds` | List valid `--sound` names. |
| `pesterm sample <name>` | Play a sound by name to audition it. |
| `pesterm post --message …` | Post a notification directly (used by the adapters internally). Accepts `--sound <name>` and `--timeout <seconds>`. |

## Uninstall

```sh
pesterm unwire claude
rm -rf ~/.local/share/pesterm/pesterm.app ~/.local/bin/pesterm
```

## More

- **[SETUP.md](./SETUP.md)** — one-time grants and manual hook wiring
- **[DESIGN.md](./DESIGN.md)** — architecture and roadmap

## License

[MIT](./LICENSE) © luinstra
