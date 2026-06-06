import Foundation
import UserNotifications

/// Pure helpers for the permission flow — the AppKit-free logic that the notification
/// backend's delegate methods call so it can be unit-tested headlessly.
enum PermissionFlow {

    /// The fail-safe timeout. Armed at `post()` ENTRY (before `requestAuthorization`,
    /// the auth-gap fix). On fire pesterm emits NOTHING and exits 0 so Claude falls back
    /// to its terminal prompt — NEVER an auto-allow. Must be well under the UN backend's
    /// 600s max lifetime so it wins the race against Claude's 600s hook timeout.
    static let timeoutSeconds: TimeInterval = 120

    /// The category id carrying the Approve/Deny actions.
    static let categoryIdentifier = "pesterm.permission"

    /// Action identifiers. Approve is primary, Deny second (banner supports two).
    static let approveActionIdentifier = "pesterm.approve"
    static let denyActionIdentifier = "pesterm.deny"

    /// PURE: map a notification-response action identifier to a decision, or nil when
    /// the user clicked the BODY (the default action / no action button) or any unknown
    /// id. A nil result means REVEAL the terminal and KEEP WAITING — do NOT resolve.
    static func decision(forActionIdentifier id: String?) -> PermissionDecision? {
        switch id {
        case approveActionIdentifier:
            return .allow
        case denyActionIdentifier:
            return .deny
        default:
            // UNNotificationDefaultActionIdentifier (body click) / nil / unknown.
            return nil
        }
    }

    /// PURE: the (stdout, exitCode) emission for a decision. allow/deny -> (json, 0);
    /// timeout -> (nil, 0). EVERY exit code is 0.
    static func emission(for decision: PermissionDecision) -> (stdout: String?, exitCode: Int32) {
        return (PermissionDecision.outputJSON(for: decision), 0)
    }
}
