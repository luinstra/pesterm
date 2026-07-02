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
        /// A body/default click for another process's notification → reveal THAT
        /// notification's target (from the response's userInfo — never our own env
        /// fallback). The OS delivered the tap HERE; the owner will never see it, and for
        /// an info notification reveal-on-click is its entire purpose.
        case revealForeign
    }

    /// PURE: classify a received response from `responseId` (the tapped notification's id),
    /// `myId` (this process's own delivered id, nil before it is set), and `actionId`.
    static func route(responseId: String, myId: String?, actionId: String?) -> TapRouting {
        if let decision = decision(forActionIdentifier: actionId) {
            return responseId == myId ? .resolveOwn(decision)
                                      : .recordForOther(id: responseId, decision)
        }
        // No decision → body / default / unknown action.
        return responseId == myId ? .revealOwn : .revealForeign
    }

    /// What the receiving process DOES with a routed tap, by its own request kind.
    /// Foreign traffic (recordForOther / revealForeign) is handled identically for both
    /// kinds — an info process must never swallow another process's Approve just because
    /// the tap wasn't for it. Only the OWN cases differ: info reveals-then-exits,
    /// permission keeps its run loop waiting for a decision.
    enum ResponseAction: Equatable {
        case resolveOwn(PermissionDecision)
        case recordForOther(id: String, PermissionDecision)
        /// Info's reveal-then-exit path (also the defensive mapping for the unreachable
        /// info+resolveOwn combination — info notifications carry no Approve/Deny).
        case revealOwnThenExit
        case revealOwnKeepWaiting
        case revealForeign
    }

    /// PURE: map (this process's kind, tap routing) → the backend's action.
    static func responseAction(kind: NotificationKind, routing: TapRouting) -> ResponseAction {
        switch routing {
        case .resolveOwn(let decision):
            return kind == .permission ? .resolveOwn(decision) : .revealOwnThenExit
        case .recordForOther(let id, let decision):
            return .recordForOther(id: id, decision)
        case .revealOwn:
            return kind == .permission ? .revealOwnKeepWaiting : .revealOwnThenExit
        case .revealForeign:
            return .revealForeign
        }
    }

    /// Grace window between "our card vanished from the delivered list" and finalizing as
    /// a dismissal. A tap can be handled by a freshly RELAUNCHED responder process (the
    /// original delegate died) — cold start means the card disappears the instant the user
    /// taps, but the DecisionStore write can trail by a second or more. Finalizing
    /// immediately would eat that Approve. Long enough for the relaunch to land; short
    /// enough that a real dismissal still reaches the terminal fallback promptly.
    static let dismissGraceSeconds: TimeInterval = 3

    /// The outcome of the "card vanished" observation for a permission wait.
    enum DismissalAction: Equatable {
        /// A decision was already in the store → honor it (it was a tap, not a dismissal).
        case resolve(PermissionDecision)
        /// No decision yet, grace not yet run → wait `dismissGraceSeconds`, then re-check.
        case startGrace
        /// No decision even after the grace window → a genuine dismissal; terminal fallback.
        case finalizeDismissed
    }

    /// PURE: decide what a permission process does when its delivered card is gone.
    /// `storeDecision` is the result of a synchronous `DecisionStore.take` performed at
    /// observation time; `graceElapsed` is whether the grace window already ran.
    static func dismissalAction(storeDecision: PermissionDecision?,
                                graceElapsed: Bool) -> DismissalAction {
        if let decision = storeDecision { return .resolve(decision) }
        return graceElapsed ? .finalizeDismissed : .startGrace
    }
}
