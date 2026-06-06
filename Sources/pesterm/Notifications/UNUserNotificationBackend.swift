import Foundation
import UserNotifications

/// The notification backend. Posts via the modern UserNotifications framework
/// (UNUserNotificationCenter); requires a one-time authorization grant on first post
/// and a valid bundle identity — both satisfied by our ad-hoc-signed .app bundle (the
/// NS-first hedge proved unnecessary: UN delivers fine from this signing setup).
///
/// Two kinds of request (see `NotificationKind`):
/// - `.info`: the original reveal-then-exit notification (no category, no buttons).
/// - `.permission`: an Alerts-style notification carrying the `"pesterm.permission"`
///   category with Approve/Deny actions. Tapping Approve/Deny resolves (prints the
///   honored decision JSON + exit 0); a BODY click REVEALS the iTerm2 tab WITHOUT
///   resolving so the still-blocking run loop keeps waiting for a decision or the 120s
///   fail-safe. The fail-safe is armed at `post()` entry (before `requestAuthorization`)
///   so a never-answered first-run auth prompt still falls back. A one-shot `ResolvedGate`
///   guarantees exactly one of {action tap, fail-safe} finalizes.
///
/// Dismiss caveat: UNUserNotificationCenter has NO reliable callback for a user
/// MANUALLY dismissing a delivered notification, so there is no dismiss-driven early
/// exit. The 600s safety cap (info) / 120s fail-safe (permission) are the backstops.
final class UNUserNotificationBackend: NSObject, NotificationBackend, UNUserNotificationCenterDelegate {

    static let maxLifetimeSeconds: TimeInterval = 600

    private var onActivate: ((String?) -> Void)?
    private var deliveredIdentifier: String?
    private var capTimer: Timer?

    /// Permission-path state.
    private var requestKind: NotificationKind = .info
    private var failSafeTimer: Timer?
    private let gate = ResolvedGate()

    func post(_ request: NotificationRequest,
              onActivate: @escaping (String?) -> Void) throws {
        self.onActivate = onActivate
        self.requestKind = request.kind

        // PERMISSION: arm the 120s fail-safe FIRST, before requestAuthorization, so an
        // unanswered first-run auth prompt still falls back (the auth-gap fix). On fire:
        // emit NOTHING + exit 0 (terminal fallback), never auto-allow. Guarded by the
        // one-shot gate so it cannot also run after an Approve/Deny tap.
        if request.kind == .permission {
            let identifier = request.groupID ?? UUID().uuidString
            self.deliveredIdentifier = identifier
            let timer = Timer.scheduledTimer(
                withTimeInterval: PermissionFlow.timeoutSeconds,
                repeats: false
            ) { [weak self] _ in
                guard let self = self, self.gate.tryResolve() else { return }
                self.removePermissionNotification()
                // Emit nothing; just flush + exit 0 for the terminal fallback.
                fflush(stdout)
                exit(0)
            }
            self.failSafeTimer = timer
        }

        let center = UNUserNotificationCenter.current()
        // Set the delegate BEFORE scheduling any request.
        center.delegate = self

        // PERMISSION: register the Approve/Deny category on the SAME center instance,
        // BEFORE add(...). Info posts NO category (unchanged).
        if request.kind == .permission {
            center.setNotificationCategories([Self.permissionCategory()])
        }

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

    /// The Approve/Deny category for `.permission` notifications. Approve is the primary
    /// action, Deny second (a banner supports two). Action buttons require the Alerts
    /// presentation style — a documented manual grant (see SETUP.md / DESIGN.md).
    static func permissionCategory() -> UNNotificationCategory {
        let approve = UNNotificationAction(
            identifier: PermissionFlow.approveActionIdentifier,
            title: "Approve",
            options: []
        )
        let deny = UNNotificationAction(
            identifier: PermissionFlow.denyActionIdentifier,
            title: "Deny",
            options: [.destructive]
        )
        return UNNotificationCategory(
            identifier: PermissionFlow.categoryIdentifier,
            actions: [approve, deny],
            intentIdentifiers: [],
            options: []
        )
    }

    /// PURE: build the notification content for a request. No scheduling, no auth, no
    /// timer — pulled out so the banner's shape (title/subtitle/body/sound) is
    /// unit-testable without posting.
    ///
    /// `.permission` sets `categoryIdentifier = "pesterm.permission"` so the Approve/Deny
    /// actions render. `.info` leaves it empty: the whole banner body is the click target
    /// → `.contentsClicked` → reveal (unchanged).
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
        if request.kind == .permission {
            content.categoryIdentifier = PermissionFlow.categoryIdentifier
        }
        return content
    }

    private func schedule(_ request: NotificationRequest) {
        let content = Self.makeContent(from: request)

        // Use the group id as the request identifier so re-posts coalesce/replace.
        let identifier = self.deliveredIdentifier ?? request.groupID ?? UUID().uuidString
        self.deliveredIdentifier = identifier

        let unRequest = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // deliver immediately
        )
        UNUserNotificationCenter.current().add(unRequest) { _ in }

        // INFO: 600s cap is the SOLE dismiss backstop (Md). Withdraw then exit. The
        // PERMISSION path uses the 120s fail-safe armed in post() instead, so it does
        // NOT arm this cap.
        if request.kind == .info {
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
    }

    /// Remove the delivered + pending permission notification for the current id.
    private func removePermissionNotification() {
        guard let id = deliveredIdentifier else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present even when frontmost. For `.permission` we still present so the Approve/Deny
    /// action buttons render (this needs the Alerts system style — documented grant).
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

    /// Interaction handling, branched on kind.
    /// - INFO: in-process reveal, then exit (unchanged reveal-then-exit path).
    /// - PERMISSION: Approve/Deny resolve (print decision JSON + exit 0); a BODY/default
    ///   click REVEALS and RETURNS WITHOUT resolving (the run loop keeps waiting).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        capTimer?.invalidate()

        if requestKind == .info {
            onActivate?(response.actionIdentifier)
            completionHandler()
            exit(0)
        }

        // PERMISSION.
        let decision = PermissionFlow.decision(forActionIdentifier: response.actionIdentifier)

        guard let decision = decision else {
            // Body click / default id / unknown: REVEAL and KEEP WAITING. Do NOT
            // tryResolve(), do NOT exit, do NOT invalidate the fail-safe — the
            // Alerts notification persists and the 120s timer keeps running.
            onActivate?(response.actionIdentifier)
            completionHandler()
            return
        }

        // Approve / Deny: claim the one-shot resolution.
        guard gate.tryResolve() else {
            // The fail-safe already fired — do nothing (and it has exited).
            completionHandler()
            return
        }
        failSafeTimer?.invalidate()
        // Let the closure observe the action too (parity with the info path); the
        // permission closure does NOT reveal on an action id.
        onActivate?(response.actionIdentifier)

        if let json = PermissionDecision.outputJSON(for: decision) {
            FileHandle.standardOutput.write(Data(json.utf8))
        }
        fflush(stdout)
        removePermissionNotification()
        completionHandler()
        exit(0)
    }
}
