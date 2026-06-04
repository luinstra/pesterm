import Foundation
import ArgumentParser

/// `pesterm wire <agent>` — idempotently merge pesterm's hook into the agent's
/// settings file.
///
/// PURE CLI: runs and exits via main.swift's existing `try parsed.run(); exit(0)`
/// fallthrough, BEFORE any NSApplication is constructed (see main.swift note). Never
/// spins the AppKit run loop.
struct WireCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wire",
        abstract: "Wire pesterm's notification hook into an agent's settings (idempotent)."
    )

    @Argument(help: "Agent to wire. Supported: claude.")
    var agent: String

    @Flag(name: .long, help: "Skip the interactive confirmation prompt.")
    var yes: Bool = false

    @Option(name: .long, help: "Override the target settings file (for tests).")
    var settings: String?

    @Option(name: .long, help: "Pin the command path written into the hook (e.g. the install symlink).")
    var commandPath: String?

    func run() throws {
        guard let writer = HookWriterRegistry.writer(for: agent) else {
            Wiring.fail("unknown agent '\(agent)'. Supported: \(HookWriterRegistry.supportedAgents.joined(separator: ", "))",
                        code: 2)
        }

        let targetPath = settings ?? writer.settingsPath

        // Resolve command path. With --command-path, pin exactly that (install.sh
        // passes the stable symlink). Standalone, default to the resolved running
        // executable (the inner bundle binary for dev use).
        let resolvedExe = ExecutablePath.resolvedRunningExecutablePath()
        let command = commandPath ?? resolvedExe

        // Bundle guard: notifications require the bundle identity. Warn (don't fail)
        // when the running executable is not inside a .app — tests / `swift run` still
        // need to wire.
        if !ExecutablePath.isInsideAppBundle(resolvedExe) {
            Wiring.warn("pesterm is not running from a .app bundle; notifications require the bundle identity. Install via scripts/install.sh for a working setup.")
        }

        let current: [String: Any]
        do {
            current = try SettingsMerger.load(path: targetPath)
        } catch {
            Wiring.fail("\(error)", code: 1)
        }

        let entry = writer.makeEntry(command: command)
        let proposed: [String: Any]
        do {
            proposed = try SettingsMerger.upsert(current, event: writer.hookEvent,
                                                 isMine: writer.isMine, entry: entry)
        } catch {
            Wiring.fail("\(error)", code: 1)
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
            print("  command: \(command) \(ClaudeHookWriter.adapterFlag)")
            if let backup = backup {
                print("  backup:  \(backup)")
            }
        } catch {
            Wiring.fail("\(error)", code: 1)
        }
        Foundation.exit(0)
    }
}
