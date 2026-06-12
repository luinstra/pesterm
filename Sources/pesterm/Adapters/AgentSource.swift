import Foundation
import ArgumentParser

/// Identifies which agent harness triggered the notification, carried on the
/// `NotificationRequest` for future per-source branding. v1 renders one neutral
/// pesterm identity for all sources (§9 option (a)); the value is stored but does
/// not change the icon yet.
enum AgentSource: String, CaseIterable, ExpressibleByArgument {
    case claude
    case generic

    /// Default when `--source` is absent (Constants table).
    static let `default`: AgentSource = .generic

    init?(argument: String) {
        // Explicit, case-sensitive map; unknown values produce a parser validation error.
        guard let value = AgentSource(rawValue: argument) else { return nil }
        self = value
    }
}

extension AgentSource {
    /// The notification coalescing-group prefix for this source + notification kind. Keeps
    /// the agent-name vocabulary in ONE place: a 2nd agent adds a case here rather than
    /// scattering parallel string literals across the adapters (e.g. "codex-" / "codex-perm-").
    /// `.info` and `.permission` get distinct prefixes so the two streams never coalesce.
    func groupPrefix(for kind: NotificationKind) -> String {
        let base: String
        switch self {
        case .claude: base = "claude"
        case .generic: base = "pesterm"
        }
        switch kind {
        case .info: return "\(base)-"
        case .permission: return "\(base)-perm-"
        }
    }
}
