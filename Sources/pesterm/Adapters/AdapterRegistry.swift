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

    /// The adapter selected by an `--adapter` value, or nil if unknown (caller logs to
    /// stderr and exits `unknownAdapterExitCode`).
    static func adapter(for value: String) -> AgentAdapter.Type? {
        return adapters.first { $0.adapterValue == value }
    }

    /// Exit code for an unknown `--adapter` value: 0, per root invariant #3 (every adapter
    /// exit is 0). Claude INTERPRETS non-zero hook exits — on PermissionRequest, exit 2
    /// means DENY — so a typo'd --adapter in a hand-edited hook must degrade to the
    /// terminal prompt (silence + exit 0), never silently deny every tool call.
    static let unknownAdapterExitCode: Int32 = 0
}
