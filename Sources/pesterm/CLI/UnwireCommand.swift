import Foundation
import ArgumentParser

/// `pesterm unwire <agent>` — remove ONLY pesterm's hook entry from the agent's
/// settings file. No-op (and no backup) when nothing matches.
///
/// PURE CLI: runs and exits via main.swift's existing fallthrough before NSApplication.
struct UnwireCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unwire",
        abstract: "Remove pesterm's notification hook from an agent's settings."
    )

    @Argument(help: "Agent to unwire. Supported: claude.")
    var agent: String

    @Flag(name: .long, help: "Skip the interactive confirmation prompt.")
    var yes: Bool = false

    @Option(name: .long, help: "Override the target settings file (for tests).")
    var settings: String?

    func run() throws {
        guard let writer = HookWriterRegistry.writer(for: agent) else {
            Wiring.fail("unknown agent '\(agent)'. Supported: \(HookWriterRegistry.supportedAgents.joined(separator: ", "))",
                        code: 2)
        }

        let targetPath = settings ?? writer.settingsPath

        let current: [String: Any]
        do {
            current = try SettingsMerger.load(path: targetPath)
        } catch {
            Wiring.fail("\(error)", code: 1)
        }

        let proposed: [String: Any]
        do {
            proposed = try SettingsMerger.remove(current, event: writer.hookEvent,
                                                 isMine: writer.isMine)
        } catch {
            Wiring.fail("\(error)", code: 1)
        }

        if Wiring.equalSettings(current, proposed) {
            print("Not wired: \(agent) → \(targetPath) (no change).")
            Foundation.exit(0)
        }

        guard Wiring.confirmOrExplain(yes: yes, agent: agent, verb: "unwire") else {
            Foundation.exit(0)
        }

        do {
            let backup = try SettingsMerger.write(proposed, to: targetPath)
            print("Unwired \(agent) hook from \(targetPath)")
            if let backup = backup {
                print("  backup:  \(backup)")
            }
        } catch {
            Wiring.fail("\(error)", code: 1)
        }
        Foundation.exit(0)
    }
}
