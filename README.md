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
5. Self-wires the Claude Code notification hook into `~/.claude/settings.json`,
   pinning the stable `$PREFIX/bin/pesterm` path.
6. Prints the exact `export PATH=...` line if `$PREFIX/bin` is not on your `PATH`.
7. Prints the two one-time manual GUI grants (see SETUP.md).

The install is **idempotent** — safe to re-run. Re-running re-wires only if the hook
changed and never creates a redundant backup.

### Commands

| Command | What it does |
|---------|--------------|
| `pesterm wire <agent>` | Idempotently merge pesterm's hook into the agent's settings. |
| `pesterm unwire <agent>` | Remove **only** pesterm's hook entry; never touches unrelated hooks. |
| `pesterm status` | Report bundle path, CLI entry + on-`PATH` state, per-agent wired state (with the command path + a stale flag), running bundle identity, and the manual grants. |
| `pesterm post --message ...` | Post a notification directly (used by the adapters internally). |

Supported agent today: `claude`. Useful flags: `--yes` (skip the confirm prompt),
`--settings <path>` (override the target settings file), `--command-path <path>`
(pin the path written into the hook).

`wire`/`unwire`/`status` are **pure CLI** — they run and exit without spinning up
AppKit, so `status` returns instantly.

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

1. **Notification style must be Alerts.** Banners auto-dismiss and kill the click, so
   the reveal never fires. Set **System Settings → Notifications → pesterm →
   Alerts** once. (See SETUP.md.)
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
