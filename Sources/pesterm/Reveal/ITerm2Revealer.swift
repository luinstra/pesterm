import Foundation
import AppKit
import CITermBridge

/// iTerm2 revealer (v1). Detects via TERM_PROGRAM + ITERM_SESSION_ID, then reveals
/// the exact session in-process via ScriptingBridge + AppKit. `.precise`.
final class ITerm2Revealer: TerminalRevealer {

    /// iTerm2 bundle id (SBApplication + NSRunningApplication) — Constants table.
    static let iTermBundleID = "com.googlecode.iterm2"

    /// The iTerm2 session GUID to match — the LAST colon-component of ITERM_SESSION_ID
    /// (PP2), captured at detect time from the inherited terminal env.
    let targetSessionId: String

    var capability: RevealCapability { .precise }

    init(targetSessionId: String) {
        self.targetSessionId = targetSessionId
    }

    // MARK: - Detection

    /// Returns an instance iff env["TERM_PROGRAM"] == "iTerm.app" AND
    /// env["ITERM_SESSION_ID"] is present. Captures the session id as the LAST
    /// colon-component (PP2), matching the prototype's `${ITERM_SESSION_ID##*:}`.
    static func detect(_ env: [String: String]) -> TerminalRevealer? {
        guard env["TERM_PROGRAM"] == "iTerm.app" else { return nil }
        guard let raw = env["ITERM_SESSION_ID"], !raw.isEmpty else { return nil }
        let sessionId = Self.parseSessionId(raw)
        guard !sessionId.isEmpty else { return nil }
        return ITerm2Revealer(targetSessionId: sessionId)
    }

    /// Pure, unit-testable parse of an ITERM_SESSION_ID value into the session GUID.
    /// Format is colon-delimited `w0t0p0:GUID` (window:tab:pane:GUID); the UUID is the
    /// LAST component after the FINAL colon (NOT merely "the part after the first :").
    /// If there is no colon, the whole string is returned (defensive).
    static func parseSessionId(_ value: String) -> String {
        // String(value.split(separator: ":").last!) — but split drops empty trailing
        // fields, so use the substring after the last colon directly to be exact.
        if let range = value.range(of: ":", options: .backwards) {
            return String(value[range.upperBound...])
        }
        return value
    }

    // MARK: - Reveal

    func reveal() throws {
        // Step 1: bring iTerm2 to front via AppKit (in the hook flow it is always
        // already running, so the running-app path is the norm; C1 covers not-running).
        bringITermToFront()

        // Step 2: enumerate windows -> tabs -> sessions, match .id, select — done in
        // Objective-C (pesterm_reveal_iterm_session). ScriptingBridge's
        // SBApplication(bundleIdentifier:) returns a private dynamic subclass, so a
        // Swift `as? iTermBridgeApplication` (a real runtime is-a check) FAILS even
        // though the object responds to every message. Objective-C never does an is-a
        // check on the cast, so the traversal "just works" there. These Apple Events would
        // normally require an Automation (TCC) grant, but pesterm runs as a descendant of
        // iTerm (spawned by the hook), so this is self-automation — macOS requires no grant
        // or prompt in the normal case (and prompts on its own in any edge case that does).
        let found = pesterm_reveal_iterm_session(targetSessionId)
        if !found {
            // Fail closed: stale/closed session (or app unavailable). No user-facing
            // error path beyond stderr; iTerm2 was still fronted in step 1.
            FileHandle.standardError.write(
                Data("pesterm: iTerm2 session \(targetSessionId) not found; revealed app only\n".utf8))
        }
    }

    /// Bring iTerm2 to the foreground.
    private func bringITermToFront() {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.iTermBundleID)
        if let iterm = running.first {
            // V5: from an LSUIElement accessory app, .activateAllWindows alone may not
            // reliably raise iTerm2; add .activateIgnoringOtherApps.
            // NOTE: .activateIgnoringOtherApps is DEPRECATED on macOS 14+ — when the min
            // target moves to 14+, switch to the parameterless NSRunningApplication.activate().
            iterm.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }

        // C1: iTerm2 not running. NSWorkspace has no direct "open by bundle id"; resolve
        // via LaunchServices then openApplication. (In the hook flow this is rare.)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.iTermBundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        }
    }
}
