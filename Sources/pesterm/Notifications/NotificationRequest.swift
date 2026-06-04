import Foundation

/// The internal, backend-agnostic description of a notification to post.
/// Built by the CLI/adapter layer, consumed by a `NotificationBackend`.
struct NotificationRequest {
    var title: String
    var subtitle: String?
    var body: String
    var sound: String?
    var source: AgentSource
    /// Coalescing key. For NSUserNotification this maps to `identifier` — posting
    /// the same identifier REPLACES the prior notification (the coalescing
    /// mechanism, since NSUserNotification has no `groupID`).
    var groupID: String?

    init(
        title: String,
        subtitle: String? = nil,
        body: String,
        sound: String? = nil,
        source: AgentSource = .default,
        groupID: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.sound = sound
        self.source = source
        self.groupID = groupID
    }
}
