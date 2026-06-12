import Foundation
import AppKit
import ArgumentParser

/// `pesterm configure [agent]` — the human front door. Interactively walks tool approvals
/// and notification sound, writes the hooks (via `WiringPlan`), then reports grant state
/// and deep-links System Settings for anything missing. This REPLACES `wire`: the tested
/// merger/registry layer underneath is unchanged; `configure` is just the friendly,
/// re-runnable UX over it.
///
/// MODES:
///  - TTY without `--yes` → GUIDED: prompt approvals + sound, offer to open grant panes.
///  - `--yes` OR no TTY   → NON-INTERACTIVE: apply defaults (approvals on, default sounds,
///    overridable by `--no-approvals` / `--sound`), print a text summary, open nothing.
///    This is the path `install.sh` and CI use.
///
/// PRESERVE (don't stomp a reinstall): if pesterm is ALREADY wired for the agent and the
/// user hasn't signaled a reconfigure (`--force`, or an explicit `--no-approvals` / `--sound`),
/// configure skips the prompts AND the re-write — it just reports wired hooks + grant state.
/// This protects hand-edits (per-event `--sound`/`--timeout`, a `--no-approvals` setup) that
/// a fresh default rebuild would clobber. `--force` re-runs the full setup from scratch.
///
/// PURE-ish CLI: runs and exits via main.swift's fallthrough BEFORE NSApplication — it
/// never posts a notification, so it must NOT spin the AppKit run loop. It uses only a
/// bounded RunLoop for optional sound auditioning (like `sample`).
struct ConfigureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure",
        abstract: "Set up pesterm for an agent: tool approvals, sound, and grants (guided)."
    )

    @Argument(help: "Agent to configure. Supported: claude.")
    var agent: String = "claude"

    @Flag(name: .long, help: "Non-interactive: apply defaults without prompting (CI / scripts).")
    var yes: Bool = false

    @Flag(name: .long, help: "Disable the tool-approval (PermissionRequest) hook; wire only the Notification hook.")
    var noApprovals: Bool = false

    @Flag(name: .long, help: "Re-run setup even if pesterm is already configured — overwrites existing hook wiring (incl. hand-edited per-event sounds/timeouts). Without it, an already-wired setup is left untouched.")
    var force: Bool = false

    @Option(name: .long, help: "Notification sound override (e.g. Glass). Omit to keep per-event defaults. Run `pesterm sounds` for valid names.")
    var sound: String?

    @Option(name: .long, help: ArgumentHelp("Override the target settings file.", visibility: .private))
    var settings: String?

    @Option(name: .long, help: ArgumentHelp("Pin the command path written into the hook.", visibility: .private))
    var commandPath: String?

    func run() throws {
        let agentKey = agent.lowercased()
        let writers = HookWriterRegistry.writers(for: agentKey)
        guard !writers.isEmpty else {
            Wiring.fail("unknown agent '\(agent)'. Supported: \(HookWriterRegistry.supportedAgents.joined(separator: ", "))",
                        code: 2)
        }

        let interactive = !yes && isatty(STDIN_FILENO) != 0
        let targetPath = settings ?? writers[0].settingsPath

        // Load current settings UP FRONT so we can detect an existing setup BEFORE prompting.
        let current: [String: Any]
        do {
            current = try SettingsMerger.load(path: targetPath)
        } catch {
            Wiring.fail("\(error)", code: 1)
        }

        // PRESERVE: don't stomp a reinstall / bare re-run of an already-wired (possibly
        // hand-edited) setup. If pesterm is already wired and the user hasn't signaled a
        // reconfigure (--force / --no-approvals / --sound), skip the prompts AND the
        // re-write — just report what's wired + the grant state.
        let alreadyWired = Self.isAgentWired(current, writers: writers)
        if Self.shouldPreserveExisting(alreadyWired: alreadyWired, force: force,
                                       noApprovals: noApprovals, soundProvided: sound != nil) {
            print("pesterm is already configured for \(agentKey) → \(targetPath).")
            print("Leaving your existing hooks untouched (per-event sounds/timeouts preserved).")
            print("Re-run setup from scratch with:  pesterm configure \(agentKey) --force")
            reportWiredHooks(agentKey: agentKey, targetPath: targetPath)
            reportGrants(interactive: interactive)
            Foundation.exit(0)
        }

        // Resolve choices: flags are the defaults; interactive mode may override via prompts.
        var approvals = !noApprovals
        var soundChoice = sound

        if interactive {
            print("Configuring pesterm for \(agentKey).")
            print("")
            approvals = promptYesNo("Enable tool approvals (Approve/Deny Claude's tool calls from a notification)?",
                                    default: approvals)
            if soundChoice == nil {
                soundChoice = promptSound()
            }
            print("")
        }

        // LOUD one-time consent notice whenever approvals are ON — in BOTH modes. The
        // non-interactive paths (--yes / no TTY / curl|bash / CI) default approvals on and
        // write a blocking PermissionRequest hook, so they must warn too (not only the
        // interactive prompt branch).
        if approvals { printConsentNotice(agent: agentKey) }

        // Resolve the command path baked into the hook. With --command-path, pin exactly
        // that (install.sh passes the stable bin entry). Otherwise default to the running
        // executable.
        let resolvedExe = ExecutablePath.resolvedRunningExecutablePath()
        let command = commandPath ?? resolvedExe
        if !ExecutablePath.isInsideAppBundle(resolvedExe) {
            Wiring.warn("pesterm is not running from a .app bundle; notifications require the bundle identity. Install via scripts/install.sh for a working setup.")
        }

        // Plan → write (idempotent: byte-identical proposal is a no-op).
        let proposed: [String: Any]
        do {
            proposed = try WiringPlan.build(agent: agentKey, approvals: approvals,
                                            command: command, sound: soundChoice, current: current)
        } catch {
            Wiring.fail("\(error)", code: 1)
        }

        if Wiring.equalSettings(current, proposed) {
            print("Already configured: \(agentKey) → \(targetPath) (no change).")
        } else {
            do {
                let backup = try SettingsMerger.write(proposed, to: targetPath)
                print("Configured \(agentKey) → \(targetPath)")
                if let backup = backup {
                    print("  backup: \(backup)")
                }
            } catch {
                Wiring.fail("\(error)", code: 1)
            }
        }

        printSummary(agentKey: agentKey, targetPath: targetPath,
                     approvals: approvals, soundChoice: soundChoice,
                     command: command, interactive: interactive)
        Foundation.exit(0)
    }

    // MARK: - Prompts

    /// `[Y/n]` (default true) or `[y/N]` (default false). Empty/EOF → the default.
    private func promptYesNo(_ question: String, default def: Bool) -> Bool {
        let hint = def ? "[Y/n]" : "[y/N]"
        print("\(question) \(hint) ", terminator: "")
        guard let line = readLine() else { return def }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if answer.isEmpty { return def }
        return answer == "y" || answer == "yes"
    }

    /// Ask whether to keep the per-event default sounds; if not, read + validate a name,
    /// optionally auditioning it. Returns nil to keep defaults, or a validated sound name.
    private func promptSound() -> String? {
        let keepDefaults = promptYesNo("Notification sound — keep the per-event defaults (Morse / Hero / Pop)?",
                                       default: true)
        if keepDefaults { return nil }

        while true {
            print("Sound name (blank to keep defaults; run `pesterm sounds` for the list): ", terminator: "")
            guard let line = readLine() else { return nil }
            let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return nil }
            guard let snd = NSSound(named: NSSound.Name(name)) else {
                print("  '\(name)' not found — try again.")
                continue
            }
            if promptYesNo("Play '\(name)' to audition it?", default: false) {
                audition(snd)
            }
            if promptYesNo("Use '\(name)' for all wired events?", default: true) {
                return name
            }
            // else loop and ask for another name.
        }
    }

    /// Play `sound` and pump a bounded RunLoop until it finishes (mirrors `sample`).
    private func audition(_ sound: NSSound) {
        sound.play()
        let deadline = Date().addingTimeInterval(10)
        while sound.isPlaying && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private func printConsentNotice(agent: String) {
        print("")
        print("⚠ Tool approvals are ON — you'll approve Claude's tool calls from a pesterm")
        print("  notification (Approve/Deny). Disable later with:")
        print("    pesterm configure \(agent) --no-approvals")
        print("")
    }

    // MARK: - Summary + grants

    private func printSummary(agentKey: String, targetPath: String,
                             approvals: Bool, soundChoice: String?,
                             command: String, interactive: Bool) {
        reportWiredHooks(agentKey: agentKey, targetPath: targetPath)
        if let soundChoice = soundChoice {
            print("  sound: \(soundChoice) (all events)")
        } else {
            print("  sound: per-event defaults (Morse / Hero / Pop)")
        }
        reportGrants(interactive: interactive)
    }

    /// Report which of the agent's hooks are currently wired (reads the live settings).
    /// Reused by the configure summary AND the preserve path.
    private func reportWiredHooks(agentKey: String, targetPath: String) {
        print("")
        print("Wired hooks:")
        let writers = HookWriterRegistry.writers(for: agentKey)
        if let s = try? SettingsMerger.load(path: targetPath) {
            for writer in writers {
                let entries = ((s["hooks"] as? [String: Any])?[writer.hookEvent] as? [Any]) ?? []
                let wired = entries.contains { writer.isMine($0) }
                print("  \(writer.hookEvent): \(wired ? "wired" : "not wired")")
            }
        }
    }

    /// Report (and, when interactive, offer to fix) the notifications grant — the only grant
    /// pesterm needs (the reveal is self-automation from an iTerm-descendant process). Live-
    /// read from the pure-CLI path; never prompts for the grant itself.
    private func reportGrants(interactive: Bool) {
        print("")
        print("Grants:")
        let notif = GrantStatus.notificationStatus()
        print("  notifications: \(describe(notif))")

        if notif != .granted {
            if interactive,
               promptYesNo("Open System Settings → Notifications to enable pesterm?", default: true) {
                openPane(Self.notificationsPaneURL)
            } else {
                print("    → enable under System Settings → Notifications → pesterm")
            }
        }
    }

    // MARK: - Existing-setup detection (PURE, testable)

    /// PURE: is any of `writers`' hook events already populated with a pesterm-owned entry?
    /// "Already wired" = at least one pesterm hook present (a no-approvals setup still has
    /// the Notification hook), so a reinstall preserves it rather than rebuilding defaults.
    static func isAgentWired(_ settings: [String: Any], writers: [HookWriter]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any]
        for writer in writers {
            let entries = (hooks?[writer.hookEvent] as? [Any]) ?? []
            if entries.contains(where: { writer.isMine($0) }) { return true }
        }
        return false
    }

    /// PURE: should configure PRESERVE the existing wiring (skip prompts + skip re-write)?
    /// Only when pesterm is already wired AND the user gave no reconfigure signal: no
    /// `--force`, no explicit `--no-approvals`, no explicit `--sound`.
    static func shouldPreserveExisting(alreadyWired: Bool, force: Bool,
                                       noApprovals: Bool, soundProvided: Bool) -> Bool {
        return alreadyWired && !force && !noApprovals && !soundProvided
    }

    private func describe(_ state: GrantState) -> String {
        switch state {
        case .granted:       return "granted"
        case .denied:        return "DENIED — needs your action"
        case .notDetermined: return "not yet granted"
        case .unknown:       return "unknown (can't confirm)"
        }
    }

    /// Open a System Settings deep-link via `/usr/bin/open` (no AppKit run loop needed).
    private func openPane(_ url: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = [url]
        try? proc.run()
        proc.waitUntilExit()
    }

    // MARK: - Constants

    static let notificationsPaneURL = "x-apple.systempreferences:com.apple.preference.notifications"
}
