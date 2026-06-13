import Foundation
import CITermBridge

/// iTerm2 revealer (v1). Detects via TERM_PROGRAM + ITERM_SESSION_ID, then reveals
/// the exact session in-process via ScriptingBridge + AppKit. `.precise`.
final class ITerm2Revealer: TerminalRevealer {

    /// iTerm2 bundle id (SBApplication + NSRunningApplication) — Constants table.
    static let iTermBundleID = "com.googlecode.iterm2"

    /// Terminal tag in the reveal-target userInfo handoff (distinguishes terminals when
    /// reconstructing a revealer from a notification click).
    static let terminalTag = "iterm2"

    /// The iTerm2 session GUID to match — the LAST colon-component of ITERM_SESSION_ID
    /// (PP2), captured at detect time from the inherited terminal env.
    let targetSessionId: String

    var capability: RevealCapability { .precise }

    init(targetSessionId: String) {
        self.targetSessionId = targetSessionId
    }

    // MARK: - Reveal-target handoff (rides in the notification userInfo)

    /// The target serialized for the userInfo handoff: terminal tag + session GUID.
    var revealUserInfo: [String: String] {
        ["terminal": Self.terminalTag, "session": targetSessionId]
    }

    /// Reconstruct from a userInfo dict, or nil if it isn't ours (tag mismatch / no session).
    static func reveal(from userInfo: [String: String]) -> TerminalRevealer? {
        guard userInfo["terminal"] == terminalTag,
              let session = userInfo["session"], !session.isEmpty else { return nil }
        return ITerm2Revealer(targetSessionId: session)
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
        ITermFront.bringToFront(bundleID: Self.iTermBundleID)

        // Step 2: enumerate windows -> tabs -> sessions, match .id, select — done in
        // Objective-C (pesterm_reveal_iterm_session). ScriptingBridge's
        // SBApplication(bundleIdentifier:) returns a private dynamic subclass, so a
        // Swift `as? iTermBridgeApplication` (a real runtime is-a check) FAILS even
        // though the object responds to every message. Objective-C never does an is-a
        // check on the cast, so the traversal "just works" there. These Apple Events would
        // normally require an Automation (TCC) grant, but pesterm runs as a descendant of
        // iTerm (spawned by the hook), so this is self-automation — macOS requires no grant
        // or prompt in the normal case (and prompts on its own in any edge case that does).
        let found = pesterm_reveal_iterm_session(targetSessionId, Self.iTermBundleID)
        if !found {
            // Fail closed: stale/closed session (or app unavailable). No user-facing
            // error path beyond stderr; iTerm2 was still fronted in step 1.
            FileHandle.standardError.write(
                Data("pesterm: iTerm2 session \(targetSessionId) not found; revealed app only\n".utf8))
        }
    }
}
