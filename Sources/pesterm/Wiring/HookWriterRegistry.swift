import Foundation

/// Maps an agent name to its `HookWriter`(s). An agent may manage MULTIPLE hook events —
/// `claude` wires both a `Notification` hook (`ClaudeHookWriter`) and a blocking
/// `PermissionRequest` approval hook (`PermissionRequestHookWriter`). The wire/unwire/
/// status commands iterate `writers(for:)`. Phase 3 agents are added here as additive
/// conformances — no other code changes.
enum HookWriterRegistry {
    private static let writers: [HookWriter] = [
        ClaudeHookWriter(),
        PermissionRequestHookWriter()
    ]

    /// All writers for an agent (case-insensitive), in canonical order
    /// (Notification first, PermissionRequest second for `claude`).
    static func writers(for agent: String) -> [HookWriter] {
        let key = agent.lowercased()
        return writers.filter { $0.agentName == key }
    }

    /// Look up the FIRST writer by agent name (case-insensitive). Retained for back-compat
    /// with any single-writer caller; prefer `writers(for:)`.
    static func writer(for agent: String) -> HookWriter? {
        writers(for: agent).first
    }

    /// Sorted, DEDUPED list of supported agent names (for help text / status) — an agent
    /// with multiple writers (e.g. `claude`) is listed ONCE.
    static var supportedAgents: [String] {
        Set(writers.map { $0.agentName }).sorted()
    }
}
