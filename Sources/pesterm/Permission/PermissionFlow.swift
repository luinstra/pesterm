import Foundation
import UserNotifications

/// Pure helpers for the permission flow — the AppKit-free logic that the notification
/// backend's delegate methods call so it can be unit-tested headlessly.
enum PermissionFlow {

    /// The fail-safe timeout. Armed at `post()` ENTRY (before `requestAuthorization`,
    /// the auth-gap fix). On fire pesterm emits NOTHING and exits 0 so Claude falls back
    /// to its terminal prompt — NEVER an auto-allow. Must be well under Claude's ~600s hook
    /// timeout so it wins the race.
    static let timeoutSeconds: TimeInterval = 120

    /// Upper bound for a `--timeout` override on the permission path: stay safely under
    /// Claude's ~600s hook timeout to avoid the "stream closed before response" race
    /// (claude-code #44435). Floor avoids a uselessly-short window.
    static let maxTimeoutSeconds: TimeInterval = 590
    static let minTimeoutSeconds: TimeInterval = 5

    /// PURE: resolve the effective permission wait from an optional `--timeout` override —
    /// the default when absent/non-positive, else the override clamped to [min, max].
    static func effectiveTimeout(override: TimeInterval?) -> TimeInterval {
        guard let o = override, o > 0 else { return timeoutSeconds }
        return min(max(o, minTimeoutSeconds), maxTimeoutSeconds)
    }

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

    /// What a received notification tap means for THIS process. macOS may deliver a tap to
    /// the WRONG pesterm process (one delegate per bundle id), so a response may be for our
    /// own notification or for another process's. Pulled out of the backend so the
    /// multi-process routing is unit-testable.
    enum TapRouting: Equatable {
        /// Tap is for OUR notification and carries a decision → resolve + exit.
        case resolveOwn(PermissionDecision)
        /// Tap carries a decision but is for ANOTHER process's notification (misrouted) →
        /// hand it off via the decision store keyed by that id; keep waiting for our own.
        case recordForOther(id: String, PermissionDecision)
        /// A body/default click on OUR notification → reveal the terminal, keep waiting.
        case revealOwn
        /// A body/default click for another process's notification → ignore (don't reveal
        /// the wrong terminal; that owner isn't waiting on a body click anyway).
        case ignoreForeignBodyClick
    }

    /// PURE: classify a received response from `responseId` (the tapped notification's id),
    /// `myId` (this process's own delivered id, nil before it is set), and `actionId`.
    static func route(responseId: String, myId: String?, actionId: String?) -> TapRouting {
        if let decision = decision(forActionIdentifier: actionId) {
            return responseId == myId ? .resolveOwn(decision)
                                      : .recordForOther(id: responseId, decision)
        }
        // No decision → body / default / unknown action.
        return responseId == myId ? .revealOwn : .ignoreForeignBodyClick
    }
}
