import Foundation

/// What kind of notification this is. Gates the `categoryIdentifier` (action buttons),
/// the `willPresent` style, and the body-click behavior in the backend:
/// - `.info`: the existing reveal-then-exit notification (no action buttons).
/// - `.permission`: an Approve/Deny notification whose body click REVEALS the terminal
///   WITHOUT resolving (the blocking run loop keeps waiting for a decision or timeout).
enum NotificationKind: Equatable {
    case info
    case permission
}

/// The internal, backend-agnostic description of a notification to post.
/// Built by the CLI/adapter layer, consumed by a `NotificationBackend`.
struct NotificationRequest {
    var title: String
    var subtitle: String?
    var body: String
    var sound: String?
    var source: AgentSource
    /// Coalescing key. Maps to the UNNotificationRequest `identifier` — posting
    /// the same identifier REPLACES the prior notification (the coalescing mechanism).
    var groupID: String?
    /// Info vs. permission. Defaults to `.info` so every existing call site (the
    /// `post` subcommand, `ClaudeAdapter`) is unchanged.
    var kind: NotificationKind

    init(
        title: String,
        subtitle: String? = nil,
        body: String,
        sound: String? = nil,
        source: AgentSource = .default,
        groupID: String? = nil,
        kind: NotificationKind = .info
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sound = sound
        self.source = source
        self.groupID = groupID
        self.kind = kind
    }
}
