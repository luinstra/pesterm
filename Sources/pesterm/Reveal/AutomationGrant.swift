import Foundation
import AppKit

/// The iTerm Automation (TCC) grant — needed ONLY on the tmux reveal path. Outside tmux
/// pesterm is an iTerm descendant, so the ScriptingBridge tab-select is self-automation
/// and macOS requires no grant. Inside tmux the hook runs under the tmux server (a
/// launchd daemon), the descendant relationship is severed, and the Apple Events need the
/// one-time "pesterm wants to control iTerm2" consent. When it's missing the traversal
/// just sees zero windows — which used to surface as a misleading "no iTerm tab for tty"
/// while the real fix was a Settings toggle. These helpers make that state inspectable.
enum AutomationGrant {

    enum State: Equatable {
        case granted
        /// The user declined the consent prompt (or a profile denies it).
        case denied
        /// Consent never requested — macOS will prompt on the first tmux reveal.
        case needsPrompt
        /// Not determinable right now (e.g. iTerm2 not running); NOT a denial.
        case undetermined(String)
    }

    /// Raw OSStatus values (MacErrors.h) — not all are surfaced as Swift constants.
    static let errNotPermitted: OSStatus = -1743        // errAEEventNotPermitted
    static let errWouldRequireConsent: OSStatus = -1744 // errAEEventWouldRequireUserConsent
    static let errProcNotFound: OSStatus = -600         // procNotFound (target not running)

    /// PURE: map `AEDeterminePermissionToAutomateTarget`'s result to a state. Anything
    /// unrecognized is `.undetermined` — never `.granted` (fail safe).
    static func state(forAEResult status: OSStatus) -> State {
        switch status {
        case 0:
            return .granted
        case errNotPermitted:
            return .denied
        case errWouldRequireConsent:
            return .needsPrompt
        case errProcNotFound:
            return .undetermined("iTerm2 not running")
        default:
            return .undetermined("OSStatus \(status)")
        }
    }

    /// PURE: one-line human description for `status` output and reveal diagnostics.
    /// Actionable when action is needed — names the exact Settings pane.
    static func describe(_ state: State) -> String {
        switch state {
        case .granted:
            return "granted"
        case .denied:
            return "DENIED — enable pesterm → iTerm2 under System Settings → "
                 + "Privacy & Security → Automation"
        case .needsPrompt:
            return "not yet requested (macOS prompts on the first tmux reveal)"
        case .undetermined(let why):
            return "undetermined (\(why))"
        }
    }

    /// IMPURE: ask TCC whether we may automate iTerm2. `askUserIfNeeded: false` — this
    /// NEVER triggers the consent prompt (status/diagnostics must stay side-effect-free);
    /// the prompt still appears naturally on the first real reveal attempt.
    static func checkITerm() -> State {
        let target = NSAppleEventDescriptor(bundleIdentifier: ITerm2Revealer.iTermBundleID)
        guard let aeDesc = target.aeDesc else { return .undetermined("no AEDesc") }
        let status = AEDeterminePermissionToAutomateTarget(
            aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
        return state(forAEResult: status)
    }
}
