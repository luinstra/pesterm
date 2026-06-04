# pesterm

**Your CLI agent pesters you back to the right terminal tab.**

A native macOS notifier for terminal-based AI coding agents — Claude Code, Codex,
Gemini CLI, and Antigravity (`agy`). When an agent needs you (permission, a
question, or it just finished a turn), pesterm posts a notification; click it and
you land on the **exact terminal tab** the agent is running in.

> Status: **design phase** — no code yet. See **[DESIGN.md](./DESIGN.md)** for the
> architecture, the abstraction layers, and the roadmap.

It replaces the working bash proof-of-concept at
[claude-notify-kit](https://github.com/luinstra/claude-notify-kit) with a single,
self-contained Swift app — no `terminal-notifier` clone, no `uv`, no Python. The
whole `-execute → reveal.sh → uv → python` chain collapses into one in-process
Swift method.
