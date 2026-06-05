import Foundation
import AppKit

/// v1 backend on NSUserNotification (deprecated since 10.14 but still functional;
/// chosen NS-first to avoid UN's auth prompt + stricter signing — locked decision #1).
///
/// Keep-alive policy (MF2 fix): the process stays alive until the notification is
/// ACTIVATED (clicked) or DISMISSED. A fixed short timeout would orphan a still-visible
/// Alert whose click does nothing — a crash-like regression vs the prototype. A hard
/// 600s safety cap withdraws the notification then exits, so the UI never advertises a
/// dead click target if neither event ever fires.
final class NSUserNotificationBackend: NSObject, NotificationBackend, NSUserNotificationCenterDelegate {

    /// Hard safety cap to avoid a zombie process if neither activate nor dismiss fires.
    static let maxLifetimeSeconds: TimeInterval = 600

    private var onActivate: (() -> Void)?
    private var deliveredNotification: NSUserNotification?
    private var capTimer: Timer?

    // The backend retains itself as the center delegate for the process lifetime;
    // it is also retained by the app delegate. Both keep it alive across the run loop.

    /// PURE: build the NSUserNotification for a request. No delivery, no delegate, no
    /// timer — pulled out so the banner's shape (title/subtitle/sound/identifier and the
    /// hasActionButton = false rule) is unit-testable without posting.
    ///
    /// `hasActionButton` defaults to true, which makes macOS add a default "Show" button.
    /// We don't want it — the whole banner body is already a click target
    /// (`.contentsClicked` → didActivate → reveal), so the button is redundant clutter.
    /// Killing it makes "click anywhere" the only affordance; the hover Close (✕) still
    /// dismisses-without-reveal via didDismissAlert.
    static func makeNotification(from request: NotificationRequest) -> NSUserNotification {
        let notification = NSUserNotification()
        notification.title = request.title
        notification.subtitle = request.subtitle
        notification.informativeText = request.body
        notification.hasActionButton = false
        if let sound = request.sound {
            notification.soundName = sound
        }
        // --group maps to identifier: posting the same identifier REPLACES the prior
        // notification with that identifier (NSUserNotification has no groupID).
        if let groupID = request.groupID {
            notification.identifier = groupID
        }
        return notification
    }

    func post(_ request: NotificationRequest, onActivate: @escaping () -> Void) throws {
        self.onActivate = onActivate

        let center = NSUserNotificationCenter.default
        center.delegate = self

        let notification = Self.makeNotification(from: request)

        self.deliveredNotification = notification
        center.deliver(notification)

        // Hard safety cap: withdraw the (possibly still-visible) notification BEFORE
        // exiting, so the UI never advertises a dead click target.
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.maxLifetimeSeconds,
            repeats: false
        ) { [weak self] _ in
            if let n = self?.deliveredNotification {
                NSUserNotificationCenter.default.removeDeliveredNotification(n)
            }
            exit(0)
        }
        self.capTimer = timer
    }

    // MARK: - NSUserNotificationCenterDelegate

    /// Show the notification even if pesterm is frontmost.
    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        shouldPresent notification: NSUserNotification
    ) -> Bool {
        return true
    }

    /// Delivery check (Mc): proves the notification POSTED. Logged to stderr so the
    /// ~10-trial reliability gate can score DELIVERY separately from ACTIVATION. A
    /// delivery failure points at bundle registration / Alerts setting, not NS itself.
    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        didDeliver notification: NSUserNotification
    ) {
        FileHandle.standardError.write(Data("pesterm: notification delivered\n".utf8))
    }

    /// Click (activation): run reveal in-process, then exit cleanly.
    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        didActivate notification: NSUserNotification
    ) {
        capTimer?.invalidate()
        onActivate?()
        exit(0)
    }

    /// Dismiss (Alert style only): end the process cleanly so a dismissed notification
    /// does not leave a zombie keep-alive process.
    ///
    /// V7 caveat: didDismissAlert does NOT fire on OS-clear, reboot, sleep, or another
    /// app's removeAllDeliveredNotifications — those cases are unhandleable and
    /// acceptable for Phase 1 (the 600s cap covers the no-event case). This is NOT a
    /// "zombie notification" bug.
    func userNotificationCenter(
        _ center: NSUserNotificationCenter,
        didDismissAlert notification: NSUserNotification
    ) {
        capTimer?.invalidate()
        exit(0)
    }
}
