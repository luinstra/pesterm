import Foundation

/// One conformance per agent. Supplies the agent's identity, its settings file path,
/// the hook event name, an `isMine` predicate (used to find/remove pesterm's own
/// entry regardless of the command path it points at), and `makeEntry(command:)` which
/// produces the canonical hook entry.
///
/// Phase 3 agents (codex/gemini/antigravity) are ADDITIVE conformances: they reuse
/// `SettingsMerger` and the CLI commands unchanged — adding one requires NO merger or
/// CLI edits, only a new conformance + a registry line.
protocol HookWriter {
    /// Lowercased agent key, e.g. "claude".
    var agentName: String { get }
    /// Expanded absolute path to the agent's settings file.
    var settingsPath: String { get }
    /// The hook event under `hooks` we manage, e.g. "Notification".
    var hookEvent: String { get }
    /// True iff `entry` is pesterm's own hook entry (matches regardless of path).
    func isMine(_ entry: Any) -> Bool
    /// Build the canonical hook entry. `command` is the bare executable path; the
    /// writer appends its own adapter flag(s).
    func makeEntry(command: String) -> [String: Any]
}
