import Foundation
import UserNotifications

/// PC1 contingency backend (V6). NOT wired by default — NSUserNotificationBackend
/// is v1. This exists so the escalation is concrete and executable IF the Task 3
/// reliability gate sees an ACTIVATION miss during click trials (>= 1 miss across
/// ~10 click trials triggers the swap). Only this file + entitlement/auth setup
/// change; core, reveal, adapter, and keep-alive wiring are untouched.
///
/// Md caveat: dismiss parity does NOT carry over. UNUserNotificationCenter has NO
/// reliable callback for a user MANUALLY dismissing a delivered notification (unlike
/// NS's didDismissAlert). In this path the 600s safety cap (+ withdraw) is the SOLE
/// dismiss backstop; manual-dismiss-driven early exit is an NS-path-only behavior.
final class UNUserNotificationBackend: NSObject, NotificationBackend, UNUserNotificationCenterDelegate {

    static let maxLifetimeSeconds: TimeInterval = 600

    private var onActivate: (() -> Void)?
    private var deliveredIdentifier: String?
    private var capTimer: Timer?

    func post(_ request: NotificationRequest, onActivate: @escaping () -> Void) throws {
        self.onActivate = onActivate

        let center = UNUserNotificationCenter.current()
        // Set the delegate BEFORE scheduling any request.
        center.delegate = self

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            // Proceed once authorization returns. On denial we degrade to whatever the
            // system allows (often banner-only); we still schedule the request.
            guard let self = self else { return }
            _ = granted // denial => degrade; no hard failure for Phase 1.
            DispatchQueue.main.async {
                self.schedule(request)
            }
        }
    }

    private func schedule(_ request: NotificationRequest) {
        let content = UNMutableNotificationContent()
        content.title = request.title
        if let subtitle = request.subtitle {
            content.subtitle = subtitle
        }
        content.body = request.body
        if let sound = request.sound {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
        }

        // Use the group id as the request identifier so re-posts coalesce/replace.
        let identifier = request.groupID ?? UUID().uuidString
        self.deliveredIdentifier = identifier

        let unRequest = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(unRequest) { _ in }

        // 600s cap is the SOLE dismiss backstop in the UN path (Md). Withdraw then exit.
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.maxLifetimeSeconds,
            repeats: false
        ) { [weak self] _ in
            if let id = self?.deliveredIdentifier {
                UNUserNotificationCenter.current()
                    .removeDeliveredNotifications(withIdentifiers: [id])
            }
            exit(0)
        }
        self.capTimer = timer
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present even when frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    /// Click handling: run reveal in-process, then exit. Call the completion handler.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        capTimer?.invalidate()
        onActivate?()
        completionHandler()
        exit(0)
    }
}
