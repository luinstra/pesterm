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
