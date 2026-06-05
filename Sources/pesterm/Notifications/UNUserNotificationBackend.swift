import Foundation
import UserNotifications

/// The notification backend. Posts via the modern UserNotifications framework
/// (UNUserNotificationCenter); requires a one-time authorization grant on first post
/// and a valid bundle identity — both satisfied by our ad-hoc-signed .app bundle (the
/// NS-first hedge proved unnecessary: UN delivers fine from this signing setup).
///
/// Dismiss caveat: UNUserNotificationCenter has NO reliable callback for a user
/// MANUALLY dismissing a delivered notification, so there is no dismiss-driven early
/// exit. The 600s safety cap (+ withdraw) is the SOLE backstop when neither a click
/// nor the cap's own timeout fires.
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

    /// PURE: build the notification content for a request. No scheduling, no auth, no
    /// timer — pulled out so the banner's shape (title/subtitle/body/sound) is
    /// unit-testable without posting. No action button is added: UN shows none by
    /// default (no UNNotificationCategory registered), so the whole banner body is the
    /// click target → `.contentsClicked` → reveal.
    static func makeContent(from request: NotificationRequest) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = request.title
        if let subtitle = request.subtitle {
            content.subtitle = subtitle
        }
        content.body = request.body
        if let sound = request.sound {
            content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
        }
        return content
    }

    private func schedule(_ request: NotificationRequest) {
        let content = Self.makeContent(from: request)

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
