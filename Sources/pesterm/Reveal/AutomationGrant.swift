import Foundation
import AppKit

/// The Automation (TCC) grant for controlling a terminal app — needed whenever the
/// process sending the Apple Events is NOT a descendant of that app:
///  - the tmux reveal path (the hook runs under the tmux server, a launchd daemon, so
///    the iTerm descendant relationship is severed), and
///  - the Ghostty relaunch-responder click path (pesterm relaunched by LaunchServices
///    after the posting process exited is no Ghostty descendant).
/// Outside those, reveals are self-automation and macOS requires no grant. When the
/// grant is missing the ScriptingBridge traversal just sees zero windows — which used
/// to surface as a misleading "no tab" diagnostic while the real fix was a Settings
/// toggle. These helpers make that state inspectable.
///
/// Every helper takes the app name/bundle explicitly — NO defaulted parameters (a
/// default would silently reintroduce a wrong-app string at a new call site).
enum AutomationGrant {

    enum State: Equatable {
        case granted
        /// The user declined the consent prompt (or a profile denies it).
        case denied
        /// Consent never requested — macOS will prompt on the first reveal that needs it.
        case needsPrompt
        /// Not determinable right now (e.g. the target app not running); NOT a denial.
        case undetermined(String)
    }

    /// Raw OSStatus values (MacErrors.h) — not all are surfaced as Swift constants.
    static let errNotPermitted: OSStatus = -1743        // errAEEventNotPermitted
    static let errWouldRequireConsent: OSStatus = -1744 // errAEEventWouldRequireUserConsent
    static let errProcNotFound: OSStatus = -600         // procNotFound (target not running)

    /// PURE: map `AEDeterminePermissionToAutomateTarget`'s result to a state. Anything
    /// unrecognized is `.undetermined` — never `.granted` (fail safe). `appName` threads
    /// into the not-running message (a hardcoded app would misreport for the other).
    static func state(forAEResult status: OSStatus, appName: String) -> State {
        switch status {
        case 0:
            return .granted
        case errNotPermitted:
            return .denied
        case errWouldRequireConsent:
            return .needsPrompt
        case errProcNotFound:
            return .undetermined("\(appName) not running")
        default:
            return .undetermined("OSStatus \(status)")
        }
    }

    /// PURE: one-line human description for `status` output and reveal diagnostics.
    /// Actionable when action is needed — names the exact Settings pane and app row.
    static func describe(_ state: State, appName: String) -> String {
        switch state {
        case .granted:
            return "granted"
        case .denied:
            return "DENIED — enable pesterm → \(appName) under System Settings → "
                 + "Privacy & Security → Automation"
        case .needsPrompt:
            return "not yet requested (macOS prompts on the first \(appName) reveal that needs it)"
        case .undetermined(let why):
            return "undetermined (\(why))"
        }
    }

    /// PURE: the `pesterm status` line for an app's automation grant, or nil when the
    /// app isn't installed (no noise about grants for terminals the user doesn't have).
    /// The impure installed check (`NSWorkspace.urlForApplication`) stays in the caller;
    /// this seam keeps the line text headlessly testable.
    static func statusLine(appName: String, installed: Bool, state: State) -> String? {
        guard installed else { return nil }
        return "\(appName) automation (needed for the jump-to-tab reveal): "
             + describe(state, appName: appName)
    }

    /// IMPURE: ask TCC whether we may automate the app with `bundleID`.
    /// `askUserIfNeeded: false` — this NEVER triggers the consent prompt
    /// (status/diagnostics must stay side-effect-free); the prompt still appears
    /// naturally on the first real reveal attempt.
    static func check(bundleID: String, appName: String) -> State {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let aeDesc = target.aeDesc else { return .undetermined("no AEDesc") }
        let status = AEDeterminePermissionToAutomateTarget(
            aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        return state(forAEResult: status, appName: appName)
    }

    static func checkITerm() -> State {
        return check(bundleID: ITerm2Revealer.iTermBundleID, appName: "iTerm2")
    }

    static func checkGhostty() -> State {
        return check(bundleID: GhosttyRevealer.ghosttyBundleID, appName: "Ghostty")
    }
}
