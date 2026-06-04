import Foundation

/// Maps an agent name to its `HookWriter`. Phase 3 agents are added here as additive
/// conformances — no other code changes.
enum HookWriterRegistry {
    private static let writers: [HookWriter] = [
        ClaudeHookWriter()
    ]

    /// Look up a writer by agent name (case-insensitive).
    static func writer(for agent: String) -> HookWriter? {
        let key = agent.lowercased()
        return writers.first { $0.agentName == key }
    }

    /// Sorted list of supported agent names (for help text / status).
    static var supportedAgents: [String] {
        writers.map { $0.agentName }.sorted()
    }
}
