import Foundation
import ArgumentParser

/// `pesterm wire <agent>` — idempotently merge pesterm's hooks into the agent's
/// settings file. For `claude` this wires BOTH a `Notification` hook and a blocking
/// `PermissionRequest` tool-approval hook (Approve/Deny notification). Approvals are ON
/// by default; pass `--no-approvals` to wire only the Notification hook.
///
/// PURE CLI: runs and exits via main.swift's existing `try parsed.run(); exit(0)`
/// fallthrough, BEFORE any NSApplication is constructed (see main.swift note). Never
/// spins the AppKit run loop.
struct WireCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire",
        abstract: "Wire pesterm's hooks into an agent's settings (idempotent)."
    )

    @Argument(help: "Agent to wire. Supported: claude.")
    var agent: String

    @Flag(name: .long, help: "Skip the interactive confirmation prompt.")
    var yes: Bool = false

    @Flag(name: .long, help: "Do NOT wire the tool-approval (PermissionRequest) hook; wire only the Notification hook.")
    var noApprovals: Bool = false

    @Option(name: .long, help: "Override the target settings file (for tests).")
    var settings: String?

    @Option(name: .long, help: "Pin the command path written into the hook (e.g. the install symlink).")
    var commandPath: String?

    @Option(name: .long, help: "Override the notification sound in the wired Notification hook (e.g. Glass). Omit to keep the per-event defaults. Run `pesterm sounds` for valid names.")
    var sound: String?

    func run() throws {
        let allWriters = HookWriterRegistry.writers(for: agent)
        guard !allWriters.isEmpty else {
            Wiring.fail("unknown agent '\(agent)'. Supported: \(HookWriterRegistry.supportedAgents.joined(separator: ", "))",
                        code: 2)
        }

        // Approvals ON => upsert BOTH hooks. --no-approvals => upsert the Notification
        // hook AND actively REMOVE any existing PermissionRequest entry, so disabling
        // approvals truly disables a previously-wired approval hook (not just skips it).
        let approvalsWired = !noApprovals
            && allWriters.contains { $0 is PermissionRequestHookWriter }

        // All writers for an agent share a settings path; use the first.
        let targetPath = settings ?? allWriters[0].settingsPath

        // Resolve command path. With --command-path, pin exactly that (install.sh
        // passes the stable symlink). Standalone, default to the resolved running
        // executable (the inner bundle binary for dev use).
        let resolvedExe = ExecutablePath.resolvedRunningExecutablePath()
        let command = commandPath ?? resolvedExe

        // Bundle guard: notifications require the bundle identity. Warn (don't fail)
        // when the running executable is not inside a .app.
        if !ExecutablePath.isInsideAppBundle(resolvedExe) {
            Wiring.warn("pesterm is not running from a .app bundle; notifications require the bundle identity. Install via scripts/install.sh for a working setup.")
        }

        // load-once / fold each selected writer's upsert / write-once => single backup.
        let current: [String: Any]
        do {
            current = try SettingsMerger.load(path: targetPath)
        } catch {
            Wiring.fail("\(error)", code: 1)
        }

        var proposed = current
        for writer in allWriters {
            if writer is PermissionRequestHookWriter && noApprovals {
                // Disabling approvals: REMOVE any existing approval hook (don't just skip
                // the event, or a previously-wired hook would survive a --no-approvals
                // re-wire). No-op when none is present.
                do {
                    proposed = try SettingsMerger.remove(proposed, event: writer.hookEvent,
                                                         isMine: writer.isMine)
                } catch {
                    Wiring.fail("\(error)", code: 1)
                }
                continue
            }
            // Build the entry. For the Notification (Claude) writer, choose the
            // `notification_type` matcher: when approvals are ALSO wired, OMIT
            // `permission_prompt` from the matcher — the PermissionRequest approval hook
            // handles it, so otherwise the user gets two banners for one permission. The
            // PermissionRequest writer ignores `sound:`; the Notification writer applies it.
            let entry: [String: Any]
            if writer is ClaudeHookWriter {
                let nw = ClaudeHookWriter(matcher: approvalsWired
                    ? ClaudeHookWriter.handledNotificationTypesNoPermission
                    : ClaudeHookWriter.handledNotificationTypes)
                entry = nw.makeEntry(command: command, sound: sound)
            } else {
                entry = writer.makeEntry(command: command, sound: sound)
            }
            do {
                proposed = try SettingsMerger.upsert(proposed, event: writer.hookEvent,
                                                     isMine: writer.isMine, entry: entry)
            } catch {
                Wiring.fail("\(error)", code: 1)
            }
        }

        if Wiring.equalSettings(current, proposed) {
            print("Already wired: \(agent) → \(targetPath) (no change).")
            Foundation.exit(0)
        }

        guard Wiring.confirmOrExplain(yes: yes, agent: agent, verb: "wire") else {
            Foundation.exit(0)
        }

        do {
            let backup = try SettingsMerger.write(proposed, to: targetPath)
            print("Wired \(agent) hook → \(targetPath)")

            // Always print the Notification command line (mirrors what was wired).
            var notifSummary = "\(command) \(ClaudeHookWriter.adapterFlag)"
            if let sound = sound, !sound.isEmpty {
                notifSummary += " --sound \(sound)"
            }
            print("  Notification:      \(notifSummary)")

            // The PermissionRequest line + the LOUD consent notice ONLY when approvals
            // are wired.
            if approvalsWired {
                print("  PermissionRequest: \(command) \(PermissionRequestHookWriter.adapterFlag)")
                print("")
                print("⚠ Tool approvals are ON — you'll approve Claude's tool calls from a pesterm")
                print("  notification (Approve/Deny). Disable with: pesterm wire claude --no-approvals")
            }

            if let backup = backup {
                print("  backup:  \(backup)")
            }
        } catch {
            Wiring.fail("\(error)", code: 1)
        }
        Foundation.exit(0)
    }
}
