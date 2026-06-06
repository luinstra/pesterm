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

        // Resolve choices: flags are the defaults; interactive mode may override via prompts.
        var approvals = !noApprovals
        var soundChoice = sound

        if interactive {
            print("Configuring pesterm for \(agentKey).")
            print("")
            approvals = promptYesNo("Enable tool approvals (Approve/Deny Claude's tool calls from a notification)?",
                                    default: approvals)
            if approvals { printConsentNotice(agent: agentKey) }
            if soundChoice == nil {
                soundChoice = promptSound()
            }
            print("")
        }

        // Resolve the command path baked into the hook. With --command-path, pin exactly
        // that (install.sh passes the stable bin entry). Otherwise default to the running
        // executable.
        let resolvedExe = ExecutablePath.resolvedRunningExecutablePath()
        let command = commandPath ?? resolvedExe
        if !ExecutablePath.isInsideAppBundle(resolvedExe) {
            Wiring.warn("pesterm is not running from a .app bundle; notifications require the bundle identity. Install via scripts/install.sh for a working setup.")
        }

        let targetPath = settings ?? writers[0].settingsPath

        // Load → plan → write (idempotent: byte-identical proposal is a no-op).
        let current: [String: Any]
        do {
            current = try SettingsMerger.load(path: targetPath)
        } catch {
            Wiring.fail("\(error)", code: 1)
        }

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
        if let soundChoice = soundChoice {
            print("  sound: \(soundChoice) (all events)")
        } else {
            print("  sound: per-event defaults (Morse / Hero / Pop)")
        }

        // Grant state (live-read from the pure-CLI path; never prompts).
        print("")
        print("Grants:")
        let notif = GrantStatus.notificationStatus()
        let automation = GrantStatus.automationStatus(bundleID: Self.iTermBundleID)
        print("  notifications:        \(describe(notif))")
        print("  iTerm2 automation:    \(describe(automation))")

        if interactive {
            if notif != .granted,
               promptYesNo("Open System Settings → Notifications to enable pesterm?", default: true) {
                openPane(Self.notificationsPaneURL)
            }
            if automation != .granted,
               promptYesNo("Open System Settings → Privacy → Automation for iTerm2?", default: true) {
                openPane(Self.automationPaneURL)
            }
        } else {
            if notif != .granted {
                print("    → enable under System Settings → Notifications → pesterm")
            }
            if automation != .granted {
                print("    → enable under System Settings → Privacy & Security → Automation")
            }
        }

        // Alert Style FYI — user preference, NOT a gate. Mentioned once.
        print("")
        print("FYI: a Temporary alert style auto-dismisses and can eat the click-to-reveal.")
        print("     Set Alert Style = Persistent under System Settings → Notifications → pesterm")
        print("     if you want reveal to be reliable. (Your call — pesterm doesn't change it.)")
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

    static let iTermBundleID = "com.googlecode.iterm2"
    static let notificationsPaneURL = "x-apple.systempreferences:com.apple.preference.notifications"
    static let automationPaneURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
}
