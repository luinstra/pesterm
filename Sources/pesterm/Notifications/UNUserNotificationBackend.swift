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
///   resolving so the run loop keeps waiting for a decision or the 120s fail-safe. The
///   fail-safe is armed at `post()` entry (before `requestAuthorization`) so a never-
///   answered first-run auth prompt still falls back. A one-shot `ResolvedGate` guarantees
///   exactly one of {own tap, decision-store poll, fail-safe} finalizes.
///
/// CROSS-PROCESS HANDOFF: macOS delivers an action tap to ONE delegate per bundle id, not
/// necessarily the process that POSTED the notification. So a tap for our notification may
/// arrive at a DIFFERENT pesterm process (and vice-versa). Each permission post uses a
/// UNIQUE id; a process that receives a tap for an id that ISN'T its own writes the decision
/// to `DecisionStore` keyed by that id, and every process polls the store for its OWN id.
/// That routes each decision to its rightful waiter regardless of which delegate the OS
/// happened to hand the tap to (see `DecisionStore`).
///
/// Dismiss handling: UNUserNotificationCenter has NO callback for a user MANUALLY
/// dismissing a delivered notification. Without one, a process would idle until its cap
/// (180s info / 120s permission) even though its notification is long gone — a zombie that
/// is ALSO a stale notification delegate stealing taps from live notifications. So we POLL
/// `getDeliveredNotifications`: once our notification has appeared and then disappears
/// (dismissed / cleared / expired), we exit. The caps remain the hard backstop.
final class UNUserNotificationBackend: NSObject, NotificationBackend, UNUserNotificationCenterDelegate {

    /// Hard backstop for an IGNORED info notification (neither clicked nor dismissed — left
    /// sitting in Notification Center). Normally the process exits far sooner via click or
    /// dismissal (W5). 3 min: a ping you haven't touched in that long is stale.
    static let maxLifetimeSeconds: TimeInterval = 180
    /// Floor for a `--timeout` info-cap override (too-short is useless). No hard upper —
    /// an info ping may legitimately persist a while.
    static let minInfoCapSeconds: TimeInterval = 5

    /// Grace before `exit(0)` on a TIMEOUT path so the ASYNC `removeDeliveredNotifications`
    /// issued just before has time to land — otherwise the process dies first and the card
    /// orphans in Notification Center (the stale card that later triggers a relaunch). The
    /// run loop is still live, so the deferred exit fires.
    static let withdrawFlushDelay: TimeInterval = 0.3

    /// PURE: resolve the effective info hard-cap from an optional `--timeout` override —
    /// the default when absent/non-positive, else the override floored at `minInfoCapSeconds`.
    static func effectiveInfoCap(override: TimeInterval?) -> TimeInterval {
        guard let o = override, o > 0 else { return maxLifetimeSeconds }
        return max(o, minInfoCapSeconds)
    }

    private var onActivate: ((String?, [String: String]?) -> Void)?
    private var deliveredIdentifier: String?
    private var capTimer: Timer?

    /// Permission-path state.
    private var requestKind: NotificationKind = .info
    private var failSafeTimer: Timer?
    /// Polls `DecisionStore` for OUR id so a tap delivered to another process still reaches us.
    private var pollTimer: Timer?
    private let gate = ResolvedGate()

    /// Dismissal-detection state (both kinds). `sawDelivered` latches true once our
    /// notification is observed in the delivered list, so the startup race (delivery is
    /// async; absent for the first instant) doesn't trigger a spurious immediate exit.
    private var dismissPollTimer: Timer?
    private var sawDelivered = false

    func post(_ request: NotificationRequest,
              onActivate: @escaping (String?, [String: String]?) -> Void) throws {
        self.onActivate = onActivate
        self.requestKind = request.kind

        // PERMISSION: arm the fail-safe + cross-process poll FIRST, before
        // requestAuthorization, so an unanswered first-run auth prompt still falls back
        // (the auth-gap fix) and a tap routed to us before we finish posting is still seen.
        if request.kind == .permission {
            // UNIQUE id per request (NOT the shared group): concurrent prompts must not
            // coalesce, and each needs a distinct DecisionStore key for the handoff.
            let identifier = UUID().uuidString
            self.deliveredIdentifier = identifier
            Trace.log("POST myId=\(identifier)")

            // Best-effort cleanup of orphaned decision files from dead processes.
            DecisionStore.sweepStale()

            // Fail-safe: on fire emit NOTHING + exit 0 (terminal fallback), never auto-allow.
            // Guarded by the one-shot gate so it cannot also run after a resolution.
            let timer = Timer.scheduledTimer(
                withTimeInterval: PermissionFlow.effectiveTimeout(override: request.lifetimeSeconds),
                repeats: false
            ) { [weak self] _ in
                guard let self = self else { return }
                let won = self.gate.tryResolve()
                Trace.log("FAILSAFE gateWon=\(won)")
                guard won else { return }
                self.pollTimer?.invalidate()
                self.removePermissionNotification()
                // Emit nothing; just flush for the terminal fallback. Defer exit so the
                // async card removal lands before we die (no orphan).
                fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.withdrawFlushDelay) {
                    exit(0)
                }
            }
            self.failSafeTimer = timer

            // Cross-process handoff poll: a tap for OUR notification may be delivered to a
            // different pesterm process, which records the decision in the store keyed by our
            // id. Poll for it and resolve wherever the tap actually landed.
            let poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self = self, let id = self.deliveredIdentifier else { return }
                if let decision = DecisionStore.take(id: id) {
                    Trace.log("POLL_TOOK id=\(id) decision=\(decision)")
                    self.resolvePermission(with: decision)
                }
            }
            self.pollTimer = poll
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
        // Reveal-target handoff: ride the target in userInfo so a click delivered to any
        // process reveals THIS notification's tab (not the receiver's captured tab).
        if let info = request.revealUserInfo, !info.isEmpty {
            content.userInfo = info
        }
        return content
    }

    /// Extract the reveal-target `[String: String]` embedded in a tapped notification's
    /// userInfo (nil if absent / not string-keyed). Lets a process reveal the CLICKED
    /// notification's tab even when the OS delivered the tap to the wrong process.
    private static func revealUserInfo(from response: UNNotificationResponse) -> [String: String]? {
        let raw = response.notification.request.content.userInfo
        guard !raw.isEmpty else { return nil }
        var dict: [String: String] = [:]
        for (key, value) in raw {
            if let k = key as? String, let v = value as? String { dict[k] = v }
        }
        return dict.isEmpty ? nil : dict
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
        UNUserNotificationCenter.current().add(unRequest) { error in
            Trace.log("ADDED id=\(identifier) kind=\(request.kind) error=\(String(describing: error))")
        }

        // INFO: 180s cap is the HARD backstop (Md). Withdraw then exit. The PERMISSION path
        // uses the 120s fail-safe armed in post() instead, so it does NOT arm this cap.
        // (Dismissal — below — normally exits far sooner than either cap.)
        if request.kind == .info {
            let timer = Timer.scheduledTimer(
                withTimeInterval: Self.effectiveInfoCap(override: request.lifetimeSeconds),
                repeats: false
            ) { [weak self] _ in
                Trace.log("CAP_FIRE kind=info")
                if let id = self?.deliveredIdentifier {
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(withIdentifiers: [id])
                }
                // Defer exit so the async card removal lands before we die (no orphan).
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.withdrawFlushDelay) {
                    exit(0)
                }
            }
            self.capTimer = timer
        }

        // BOTH kinds: poll for dismissal so the process dies with its notification instead
        // of idling (as a stale delegate) until the cap.
        startDismissPoll()
    }

    /// PURE: dismissal decision from a delivered-list observation. `present` = our id is in
    /// the delivered list now; `sawDelivered` = we've seen it before. Returns the updated
    /// latch and whether to exit. Exit only when ABSENT after having been seen (so the
    /// async-delivery startup race — absent for the first instant — never exits early).
    static func dismissDecision(present: Bool, sawDelivered: Bool) -> (sawDelivered: Bool, exit: Bool) {
        if present { return (true, false) }
        return (sawDelivered, sawDelivered)
    }

    /// Poll `getDeliveredNotifications` (~2s) and exit once our notification has appeared
    /// and then disappeared (dismissed / cleared / expired). Both kinds.
    private func startDismissPoll() {
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, let id = self.deliveredIdentifier else { return }
            UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
                let present = delivered.contains { $0.request.identifier == id }
                DispatchQueue.main.async {
                    let (saw, shouldExit) = Self.dismissDecision(present: present,
                                                                 sawDelivered: self.sawDelivered)
                    self.sawDelivered = saw
                    if shouldExit { self.handleDismissed() }
                }
            }
        }
        self.dismissPollTimer = timer
    }

    /// The notification was dismissed/cleared. INFO: just exit. PERMISSION: treat as the
    /// terminal fallback — emit NOTHING + exit 0 (gate-guarded), exactly like the fail-safe.
    private func handleDismissed() {
        switch requestKind {
        case .info:
            Trace.log("DISMISSED kind=info")
            capTimer?.invalidate()
            dismissPollTimer?.invalidate()
            exit(0)
        case .permission:
            guard gate.tryResolve() else { return }
            Trace.log("DISMISSED kind=permission")
            failSafeTimer?.invalidate()
            pollTimer?.invalidate()
            dismissPollTimer?.invalidate()
            removePermissionNotification()
            fflush(stdout)
            exit(0)
        }
    }

    /// Remove the delivered + pending permission notification for the current id.
    private func removePermissionNotification() {
        guard let id = deliveredIdentifier else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// Finalize OUR permission flow with `decision`: claim the one-shot gate, stop the
    /// timers, write the decision JSON to stdout, withdraw the notification, exit 0. The
    /// loser of the race (gate already claimed) just runs `completion` and returns. Called
    /// from BOTH the own-tap path (with the delegate's completion) and the decision-store
    /// poll (no completion).
    private func resolvePermission(with decision: PermissionDecision,
                                   completion: (() -> Void)? = nil) {
        let won = gate.tryResolve()
        Trace.log("RESOLVE decision=\(decision) gateWon=\(won)")
        guard won else {
            completion?()
            return
        }
        failSafeTimer?.invalidate()
        pollTimer?.invalidate()
        dismissPollTimer?.invalidate()
        if let json = PermissionDecision.outputJSON(for: decision) {
            FileHandle.standardOutput.write(Data(json.utf8))
        }
        fflush(stdout)
        removePermissionNotification()
        completion?()
        exit(0)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present even when frontmost. For `.permission` we still present so the Approve/Deny
    /// action buttons render (this needs the Alerts system style — documented grant).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Package.swift pins macOS 11 as the floor, so .banner is always available.
        completionHandler([.banner, .sound])
    }

    /// Interaction handling, branched on kind.
    /// - INFO: in-process reveal, then exit (unchanged reveal-then-exit path).
    /// - PERMISSION: routed through `PermissionFlow.route` because the OS may deliver this
    ///   tap to the wrong process. Our own Approve/Deny resolves; a tap for ANOTHER
    ///   process's notification is handed off via `DecisionStore`; our own body click
    ///   reveals; a foreign body click is ignored.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        capTimer?.invalidate()

        if requestKind == .info {
            onActivate?(response.actionIdentifier, Self.revealUserInfo(from: response))
            completionHandler()
            exit(0)
        }

        // PERMISSION.
        let responseId = response.notification.request.identifier
        Trace.log("DIDRECEIVE responseId=\(responseId) myId=\(deliveredIdentifier ?? "nil") action=\(response.actionIdentifier)")
        switch PermissionFlow.route(responseId: responseId, myId: deliveredIdentifier,
                                    actionId: response.actionIdentifier) {
        case .resolveOwn(let decision):
            // Our notification, our decision — resolve + exit (completion runs first).
            Trace.log("ROUTE=resolveOwn decision=\(decision)")
            resolvePermission(with: decision, completion: completionHandler)

        case .recordForOther(let id, let decision):
            // Misrouted: this tap is for another process's notification. Hand the decision
            // off via the store keyed by THAT id; do NOT resolve ours, do NOT exit — our own
            // tap/poll/fail-safe still has to land.
            Trace.log("ROUTE=recordForOther id=\(id) decision=\(decision)")
            DecisionStore.write(decision, forId: id)
            completionHandler()

        case .revealOwn:
            // Body/default click on OUR notification: reveal, keep waiting (no resolve).
            Trace.log("ROUTE=revealOwn")
            onActivate?(response.actionIdentifier, Self.revealUserInfo(from: response))
            completionHandler()

        case .ignoreForeignBodyClick:
            // Body click for someone else's notification — don't reveal the wrong terminal.
            Trace.log("ROUTE=ignoreForeignBodyClick")
            completionHandler()
        }
    }
}
