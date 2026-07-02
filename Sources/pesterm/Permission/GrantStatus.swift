import Foundation
import UserNotifications

/// The state of a macOS permission grant. `unknown` covers "couldn't determine" — callers
/// treat it as "can't confirm, so guide the user" rather than asserting a definite denial.
enum GrantState: String {
    case granted
    case denied
    case notDetermined
    case unknown
}

/// Reads (NEVER prompts for) the notification authorization grant from the PURE-CLI path —
/// i.e. WITHOUT constructing NSApplication or calling `app.run()`.
///
/// VALIDATED (spike, 2026-06): `getNotificationSettings` is async on a private queue;
/// bridged with a semaphore it returns in ~7ms — the callback does NOT land on the main
/// queue, so a main-thread `wait()` does not deadlock. The bounded timeout remains a
/// belt-and-suspenders escape hatch (returns `.unknown` rather than hanging) if that ever
/// changes on a future OS.
///
/// FRAGILITY (known bet, not a guarantee): the no-deadlock property is a load-bearing
/// OS-behavior ASSUMPTION. If a future macOS routes the callback to the main queue, the
/// timeout — not a hang — is what saves us, at the cost of silently under-reporting the
/// grant as `.unknown`. If `status`/`configure` ever start reporting `.unknown` spuriously,
/// this is the first place to look.
///
/// (OUTSIDE tmux pesterm needs no Automation/TCC grant for the reveal: it drives iTerm
/// from an iTerm-descendant process — self-automation. INSIDE tmux the hook runs under
/// the tmux server daemon, that relationship is severed, and the reveal needs the iTerm
/// Automation grant — see `AutomationGrant`, surfaced by `status`/`configure`.)
enum GrantStatus {

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
