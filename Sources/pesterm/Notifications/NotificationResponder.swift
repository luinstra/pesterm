import Foundation
import AppKit
import UserNotifications

/// Handles a notification click delivered to a FRESHLY-LAUNCHED process — i.e. macOS
/// relaunched `pesterm.app` to deliver an action whose original posting process already
/// exited (it hit its cap, was dismissed, or died). Without this, that bare relaunch printed
/// help and exited instantly, so macOS surfaced "The application 'pesterm' is not open
/// anymore." Here we instead stay up briefly, handle the delivered response, and exit — so
/// the click WORKS and the dialog never appears.
///
/// No posted request and (usually) no terminal env, so the reveal target comes ENTIRELY from
/// the notification's `userInfo` (the W4 reveal-target handoff). A permission Approve/Deny is
/// written to `DecisionStore` keyed by the notification id — harmless if no one is waiting,
/// and a correct cross-process handoff if the owner happens to still be alive (macOS routed
/// the click to this fresh instance instead of the owner).
///
/// If no response is delivered within `strayLaunchTimeout` (a Finder double-click or other
/// stray launch, not a notification activation), we just exit cleanly.
final class NotificationResponder: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    static let strayLaunchTimeout: TimeInterval = 5

    /// Env-detected revealer (almost always nil here — a LaunchServices relaunch has no
    /// ITERM_SESSION_ID), used only as a fallback when the notification carries no target.
    private let revealer: TerminalRevealer?
    private var timeoutTimer: Timer?

    init(revealer: TerminalRevealer?) {
        self.revealer = revealer
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Become the delegate so macOS delivers the pending response (if this launch was a
        // notification activation). Setting it here, in didFinishLaunching, is what lets the
        // OS hand us the click.
        UNUserNotificationCenter.current().delegate = self
        // The RESPONDER_* lines are the relaunch process's half of the tap timeline —
        // the LAUNCH→DIDRECEIVE→(WROTE|REVEAL) gaps split LaunchServices spawn latency
        // from delivery latency from reveal work. Without them a relaunch handling is
        // indistinguishable from a lost tap. Marker-gated only (a LaunchServices
        // relaunch inherits no curated env, so PESTERM_TRACE can never reach it).
        Trace.log("RESPONDER_LAUNCH")

        // No response within the window → stray launch (not a notification). Exit cleanly.
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: Self.strayLaunchTimeout,
                                            repeats: false) { _ in
            Trace.log("RESPONDER_STRAY no response within \(Self.strayLaunchTimeout)s")
            exit(0)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        timeoutTimer?.invalidate()
        let request = response.notification.request
        Trace.log("RESPONDER_DIDRECEIVE responseId=\(request.identifier) action=\(response.actionIdentifier)")

        // Permission Approve/Deny: hand the decision to the owning process via the store
        // (keyed by the notification id). We are NOT the owner, so we never write stdout.
        if let decision = PermissionFlow.decision(forActionIdentifier: response.actionIdentifier) {
            DecisionStore.write(decision, forId: request.identifier)
            Trace.log("RESPONDER_WROTE id=\(request.identifier) decision=\(decision)")
            completionHandler()
            exit(0)
        }

        // Body/default click: reveal the CLICKED notification's tab from its userInfo target
        // (env revealer is the fallback, normally nil for a relaunch).
        let fromUserInfo = Self.revealer(from: request.content.userInfo)
        let target = fromUserInfo ?? revealer
        Trace.log("RESPONDER_REVEAL source=\(fromUserInfo != nil ? "userInfo" : (target != nil ? "envFallback" : "none"))")
        if let target = target {
            do {
                try target.reveal()
            } catch {
                FileHandle.standardError.write(
                    Data("pesterm: reveal failed: \(error)\n".utf8))
            }
        }
        completionHandler()
        exit(0)
    }

    /// Reconstruct a revealer from a tapped notification's userInfo (the W4 handoff).
    private static func revealer(from raw: [AnyHashable: Any]) -> TerminalRevealer? {
        guard !raw.isEmpty else { return nil }
        var dict: [String: String] = [:]
        for (key, value) in raw {
            if let k = key as? String, let v = value as? String { dict[k] = v }
        }
        return dict.isEmpty ? nil : RevealerRegistry.revealer(from: dict)
    }
}
