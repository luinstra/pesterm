import Foundation

/// Holds the known agent adapters and looks one up by its `--adapter` value. Adding an
/// agent = appending a type here + one new `AgentAdapter` conformance. Mirrors
/// `RevealerRegistry` on the reveal axis. Replaces the old hardcoded `AdapterDispatch`
/// string switch.
enum AdapterRegistry {
    static let adapters: [AgentAdapter.Type] = [
        ClaudeAdapter.self,            // "claude"            — Notification hook (.info)
        ClaudePermissionAdapter.self,  // "claude-permission" — PermissionRequest hook (.permission)
    ]

    /// The adapter selected by an `--adapter` value, or nil if unknown (caller exits 2).
    static func adapter(for value: String) -> AgentAdapter.Type? {
        return adapters.first { $0.adapterValue == value }
    }
}
