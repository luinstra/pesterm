import Foundation

/// Claude Code Notification-hook adapter. Reads the hook JSON on stdin, maps the
/// `notification_type` to (message, sound) EXACTLY matching the bash prototype, and
/// builds a `NotificationRequest`. The reveal target comes from the inherited
/// ITERM_SESSION_ID env, NEVER from the payload (key invariant).
enum ClaudeAdapter {

    /// The Claude Code Notification hook stdin JSON (confirmed fields).
    struct Payload: Decodable {
        let notificationType: String?
        let message: String?
        let title: String?
        let cwd: String?
        let sessionId: String?

        enum CodingKeys: String, CodingKey {
            case notificationType = "notification_type"
            case message
            case title
            case cwd
            case sessionId = "session_id"
        }
    }

    /// Hardcoded title, matching the prototype.
    static let title = "Claude Code"

    /// Group prefix (Constants table): "claude-" + iTerm2 session id.
    static let groupPrefix = "claude-"

    /// PURE: decode the hook JSON. Returns nil for empty/invalid input (caller
    /// suppresses). Unit-testable without posting.
    static func parse(_ data: Data) -> Payload? {
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(Payload.self, from: data)
    }

    /// PURE: map a Claude `notification_type` to the prototype's (message, sound).
    /// Returns nil for BOTH the suppress branch (auth_success) and the unknown/missing
    /// branch — the caller logs the appropriate suppression line and exits 0. The
    /// prototype never notified on un-mapped events (C3).
    /// Unit-testable without posting.
    static func eventMapping(notificationType: String?) -> (message: String, sound: String?)? {
        switch notificationType {
        case "idle_prompt":
            return ("Awaiting your input", "Morse")
        case "permission_prompt":
            return ("Permission required", "Hero")
        case "elicitation_dialog":
            return ("Question for you", "Pop")
        default:
            // auth_success -> suppress for parity; unknown/missing -> suppress (C3).
            return nil
        }
    }

    /// Build a NotificationRequest from the payload + the captured iTerm2 session id.
    /// Returns nil if the event maps to a suppressed/unknown type (caller exits 0).
    /// `sessionId` is the iTerm2 session GUID parsed from the env (NOT payload.sessionId).
    static func buildRequest(from payload: Payload, iTermSessionId: String?) -> NotificationRequest? {
        guard let mapped = eventMapping(notificationType: payload.notificationType) else {
            return nil
        }
        let subtitle = projectSubtitle(cwd: payload.cwd)
        let group: String? = iTermSessionId.map { groupPrefix + $0 }
        return NotificationRequest(
            title: title,
            subtitle: subtitle,
            body: mapped.message,
            sound: mapped.sound,
            source: .claude,
            groupID: group
        )
    }

    /// PURE: subtitle = basename of cwd (mirrors `${PWD##*/}`). Falls back to the
    /// process working dir when cwd is absent/empty.
    static func projectSubtitle(cwd: String?) -> String {
        let path: String
        if let cwd = cwd, !cwd.isEmpty {
            path = cwd
        } else {
            path = FileManager.default.currentDirectoryPath
        }
        return (path as NSString).lastPathComponent
    }
}
