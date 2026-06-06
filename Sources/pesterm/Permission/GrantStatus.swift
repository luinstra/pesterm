import Foundation
import CoreServices
import UserNotifications

/// The state of a macOS permission grant pesterm depends on. `unknown` covers both
/// "couldn't determine" and "target not running" — callers treat it as "can't confirm,
/// so guide the user" rather than asserting a definite denial.
enum GrantState: String {
    case granted
    case denied
    case notDetermined
    case unknown
}

/// Reads (NEVER prompts for) the two grants `configure`/`status` care about, from the
/// PURE-CLI path — i.e. WITHOUT constructing NSApplication or calling `app.run()`.
///
/// VALIDATED (spike, 2026-06): both reads work from the pure-CLI path with no run loop —
///  1. Automation/TCC: `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded:false)`
///     returns synchronously (~50ms) and does not prompt.
///  2. Notifications: `getNotificationSettings` is async on a private queue; bridged with
///     a semaphore it returns in ~7ms — the callback does NOT land on the main queue, so
///     a main-thread `wait()` does not deadlock. The bounded timeout remains a belt-and-
///     suspenders escape hatch (returns `.unknown` rather than hanging) if that ever
///     changes on a future OS.
enum GrantStatus {

    // MARK: Automation (TCC) — e.g. iTerm2

    /// Automation/Apple-Events status for the app with `bundleID`. Synchronous; with
    /// `askUserIfNeeded == false` it NEVER shows the TCC prompt — it only reports state.
    static func automationStatus(bundleID: String) -> GrantState {
        var target = AEAddressDesc()
        let data = Data(bundleID.utf8)
        // AECreateDesc returns OSErr (Int16); compare against literal 0 to stay
        // type-agnostic.
        let createStatus = data.withUnsafeBytes { raw in
            AECreateDesc(typeApplicationBundleID, raw.baseAddress, data.count, &target)
        }
        guard createStatus == 0 else { return .unknown }
        defer { AEDisposeDesc(&target) }

        // Returns OSStatus (Int32). askUserIfNeeded:false → never prompts.
        let perm = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, false)

        switch perm {
        case 0:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .notDetermined
        default:
            // procNotFound (target not running) and anything else → can't confirm.
            return .unknown
        }
    }

    // MARK: Notifications

    /// Notification authorization status, bridged to synchronous via a semaphore so it
    /// works on the pure-CLI path with no run loop. Returns `.unknown` if the callback
    /// does not fire within `timeout` (the deadlock-safe escape hatch).
    static func notificationStatus(timeout: TimeInterval = 2) -> GrantState {
        let center = UNUserNotificationCenter.current()
        let sem = DispatchSemaphore(value: 0)
        var result: GrantState = .unknown
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                result = .granted
            case .denied:
                result = .denied
            case .notDetermined:
                result = .notDetermined
            @unknown default:
                result = .unknown
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return result
    }
}
