# pesterm

**Your CLI agent pesters you back to the right terminal tab.**

A native macOS notifier for terminal-based AI coding agents — Claude Code, Codex,
Gemini CLI, and Antigravity (`agy`). When an agent needs you (permission, a
question, or it just finished a turn), pesterm posts a notification; click it and
you land on the **exact terminal tab** the agent is running in.

It replaces the working bash proof-of-concept at
[claude-notify-kit](https://github.com/luinstra/claude-notify-kit) with a single,
self-contained Swift app — no `terminal-notifier` clone, no `uv`, no Python. The
whole `-execute → reveal.sh → uv → python` chain collapses into one in-process
Swift method.

### Tool approvals (Approve / Deny from a notification)

For Claude Code, pesterm can also be a **blocking tool-approval** hook: when Claude is
about to prompt for tool permission, pesterm posts a **Persistent notification with
Approve / Deny actions** showing the command (or the real path/url for non-Bash tools).
On macOS (Big Sur+) the Approve/Deny actions appear under the notification's **"Options"**
affordance, not as always-visible inline buttons — that's expected macOS behavior. Tap
**Approve** to allow, **Deny** to deny — no terminal `1.Yes/2.No` menu. Because approvals
own `permission_prompt`, the plain `Notification` hook's matcher drops that type when both
are wired, so one permission never produces two banners. Click the
notification **body** to reveal the terminal and read the full context WITHOUT deciding
(the notification persists; you can still tap a button or let it time out). If you don't
respond within 120 seconds — or on any error — pesterm falls back to Claude's terminal
prompt and **never auto-allows**.

Approvals are **on by default** (`pesterm configure claude`); disable with
`pesterm configure claude --no-approvals` (or answer "n" at the approvals prompt). The `PermissionRequest` hook is **interactive-only**
(it doesn't fire under headless `claude -p`), and pesterm does NOT mediate **subagent**
tool calls — those still prompt in the terminal (#23983). See **[SETUP.md](./SETUP.md)**.

See **[DESIGN.md](./DESIGN.md)** for the architecture and roadmap, and
**[SETUP.md](./SETUP.md)** for the one-time GUI grants.

## Install

One command, no sudo:

```sh
scripts/install.sh
```

This builds the release binary, assembles and ad-hoc-signs a `pesterm.app` bundle,
and:

1. Places the bundle at `$PREFIX/share/pesterm/pesterm.app`
   (default `PREFIX=$HOME/.local`; override with `PESTERM_PREFIX`). No sudo.
2. Registers it with LaunchServices.
3. Writes a CLI entry at `$PREFIX/bin/pesterm` — an `exec` wrapper that runs the
   inner bundle binary (a bare symlink would NOT carry the bundle identity; the
   wrapper is the terminal-notifier-proven pattern).
4. Verifies the bundle identity **through that entry** (asserts
   `Bundle.main.bundleIdentifier == com.luinstra.pesterm` and that the resolved
   bundle path is inside the installed `.app`). The install **fails loudly** if not.
5. Prints the exact `export PATH=...` line if `$PREFIX/bin` is not on your `PATH`.
6. Hands off to **`pesterm configure`** — the guided setup that wires the Claude Code
   hooks into `~/.claude/settings.json` (tool approvals on by default, stable
   `$PREFIX/bin/pesterm` path), then reports **live grant state** and offers to open the
   relevant System Settings panes for anything missing. It runs interactively at a
   terminal and falls back to defaults when there's no TTY (`curl | bash` / CI). See
   SETUP.md.

The install is **idempotent** — safe to re-run. Re-running re-applies only if the hooks
changed and never creates a redundant backup.

### Commands

| Command | What it does |
|---------|--------------|
| `pesterm configure <agent>` | **The front door** (replaces `wire`). Guided setup: choose tool approvals + sound, wire both hooks, then report live grant state and offer to deep-link the System Settings panes. Non-interactive with `--yes` (applies defaults). |
| `pesterm unwire <agent>` | Remove **only** pesterm's hook entries (both events); never touches unrelated hooks. |
| `pesterm status` | Report bundle path, CLI entry + on-`PATH` state, per-agent wired state (listed once, with a per-event breakdown + a stale flag), running bundle identity, and the manual grants. |
| `pesterm post --message ...` | Post a notification directly (used by the adapters internally). |
| `pesterm sounds` | List the valid `--sound` names from the standard macOS Sounds dirs (system + your customs). |
| `pesterm sample <name>` | Play a sound by name to audition it before configuring. |

Supported agent today: `claude`. Useful flags: `--yes` (non-interactive — apply
defaults without prompting, the CI / `curl | bash` path), `--no-approvals` (disable the
tool-approval hook), `--sound <name>` (override the notification sound; the tool-approval
hook ignores `--sound`).

### Sounds

Each Claude event has a default sound:

| Event | Default sound |
|-------|---------------|
| `idle_prompt` | Morse |
| `permission_prompt` | Hero |
| `elicitation_dialog` | Pop |

Override the sound for the wired hook with `--sound`:

```sh
pesterm configure claude --sound Glass     # all events use Glass instead of the defaults
```

This bakes `--sound Glass` into the hook command
(`… pesterm --adapter claude --sound Glass`). Want different sounds per event? Add a
separate matcher entry per event by hand, each with its own `--sound` — no extra code
needed.

Sound names come from the standard NSSound directories — `/System/Library/Sounds`,
`~/Library/Sounds`, and `/Library/Sounds` — so any custom sound you drop into
`~/Library/Sounds` (e.g. `notification.aiff`, `codex-notification.aiff`) is usable as a
`--sound` value. List the valid names and audition them:

```sh
pesterm sounds              # authoritative list of valid --sound values
pesterm sample Glass        # play a sound to hear it
```

Note: the newer macOS Tahoe alert sounds (Boop, etc.) are **not** name-addressable
here — only the classic `/System/Library/Sounds` set and your own custom-dir sounds
resolve by name.

`configure`/`unwire`/`status` are **pure CLI** — they run and exit without spinning up
the notification run loop, so `status` returns instantly. (`configure` reads grant state
and may briefly play a sound sample, but never enters the keep-alive path.)

### PATH

If the installer reports `$PREFIX/bin` is not on your `PATH`, add the printed line to
your shell profile, e.g.:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

### Uninstall / unwire

```sh
pesterm unwire claude          # remove only pesterm's hook
rm -rf "$HOME/.local/share/pesterm/pesterm.app" "$HOME/.local/bin/pesterm"
```

## Known wrinkles

1. **Alert Style must be Persistent.** A temporary alert auto-dismisses and kills the
   click, so the reveal never fires. Set **System Settings → Notifications → pesterm →
   Alert Style → Persistent** once (macOS renamed "Banners / Alerts" to
   "Temporary / Persistent"). (See SETUP.md.)
2. **One-time "control iTerm2" grant.** The first reveal triggers a TCC prompt; click
   OK once.
3. **TCC re-prompt on rebuild.** Ad-hoc signatures key off the bundle's cdhash, so a
   rebuild + reinstall changes the hash and **re-triggers** the "control iTerm2"
   prompt. This is expected until Phase 5 (real Developer ID signing) lands.

## Future work

- Homebrew formula (the `bin/` wrapper + `.app` layout already mirrors the
  terminal-notifier formula shape).
- Phase 3 adapters: Codex, Gemini CLI, Antigravity — each is an additive
  `HookWriter` conformance; the merger and CLI don't change.
- Phase 5: real Developer ID signing + notarization (fixes wrinkle #3).

## License

[MIT](./LICENSE) © luinstra
