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

### One-time macOS grant

**Allow notifications** for pesterm — macOS prompts the first time pesterm posts; click
**Allow**. That's the only grant pesterm needs. (The jump-to-tab reveal drives iTerm from
an iTerm-descendant process, so it needs no Automation grant.) Detail in
**[SETUP.md](./SETUP.md)**.

## Usage

### `pesterm configure`

The front door. Run it any time to change your setup — it re-reads your choices and grant
state, so it's the one command to remember.

```sh
pesterm configure                 # guided: tool approvals, sound, grant check
pesterm configure --yes           # non-interactive: apply defaults (CI / curl | bash)
pesterm configure --no-approvals  # notifications only, no tool approvals
pesterm configure --sound Glass   # use Glass instead of the per-event default sounds
```

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
full context *without* deciding. No response within 120s, or any error, falls back to
Claude's own terminal prompt and **never auto-allows**.

Caveats worth knowing:

- **Interactive-only** — doesn't fire under headless `claude -p`.
- **Subagent tool calls aren't mediated** — those still prompt in the terminal
  ([#23983](https://github.com/anthropics/claude-code/issues/23983)). No banner ≠ blocked.
- **Interactive tools aren't mediated** — `AskUserQuestion` and `ExitPlanMode` use Claude's
  native prompt (approving a question just to then answer it makes no sense).

Disable with `pesterm configure --no-approvals`.

### Sounds

Override the per-event defaults with `--sound`, or drop a custom `.aiff` into
`~/Library/Sounds` and use its name. Want a different sound per event? Hand-add a matcher
entry per event in `~/.claude/settings.json`, each with its own `--sound`.

```sh
pesterm sounds            # list valid --sound names (system + your customs)
pesterm sample Glass      # audition a sound before using it
```

Note: the newer macOS Tahoe alert sounds (Boop, etc.) aren't name-addressable — only the
classic `/System/Library/Sounds` set and your custom-dir sounds resolve by name.

### All commands

| Command | What it does |
|---------|--------------|
| `pesterm configure [agent]` | Guided setup (the front door): tool approvals, sound, grant check + deep-links. `--yes` applies defaults non-interactively. |
| `pesterm status` | Report install path, `PATH` state, per-agent wired state, running bundle identity, and the manual grants. |
| `pesterm unwire <agent>` | Remove **only** pesterm's hook entries; never touches unrelated hooks. |
| `pesterm sounds` | List valid `--sound` names. |
| `pesterm sample <name>` | Play a sound by name to audition it. |
| `pesterm post --message …` | Post a notification directly (used by the adapters internally). |

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
