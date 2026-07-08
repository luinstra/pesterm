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

    // MARK: - Focus probe (focus-aware notification deferral)

    /// Both kinds are suppressible: the session-GUID match is exact, so a hard YES on
    /// a permission can never strand an approval on the wrong tab.
    func supportsFocusSuppression(for kind: NotificationKind) -> Bool {
        return true
    }

    /// Protocol entry point — delegates to the injectable overload with the
    /// production reader (the D6 child-process ScriptingBridge read).
    func probeFocus(frontmostBundleID: String?) -> FocusVerdict {
        return probeFocus(frontmostBundleID: frontmostBundleID,
                          readValue: FocusProbeClient.readValue)
    }

    /// The orchestration seam (D3): impure edges arrive as a closure so tests can
    /// assert the Tier0 → read → compare wiring without any ScriptingBridge. Every
    /// miss is `.unverified` (fail toward posting); unverified REASONS are Trace-logged
    /// HERE — they never ride through `FocusAction`.
    func probeFocus(frontmostBundleID: String?,
                    readValue: (String, TimeInterval) -> String?) -> FocusVerdict {
        // Tier 0 (no Apple Events, ~free): iTerm must be the frontmost APP. Also
        // guarantees the SB target is running before any probe child is spawned (D7).
        guard FocusPolicy.hostIsFrontmost(expectedBundleID: Self.iTermBundleID,
                                          frontmostBundleID: frontmostBundleID) else {
            Trace.log("FOCUS_PROBE_ITERM tier0=miss frontmost=\(frontmostBundleID ?? "<nil>")")
            return .unverified("iTerm2 not frontmost")
        }
        // Tier 1: the frontmost window's current session id, read in a disposable
        // child (0.5s box). nil = timeout/empty/garbage per the D6 contract.
        guard let observed = readValue("iterm-session-id", 0.5) else {
            Trace.log("FOCUS_PROBE_ITERM read=nil verdict=unverified")
            return .unverified("probe timeout/empty")
        }
        guard observed == targetSessionId else {
            Trace.log("FOCUS_PROBE_ITERM read=\(observed) target=\(targetSessionId) verdict=unverified")
            return .unverified("another session is focused")
        }
        Trace.log("FOCUS_PROBE_ITERM read=\(observed) verdict=focused")
        return .focused
    }

    // MARK: - Reveal

    func reveal() throws {
        // Step 1: bring iTerm2 to front via AppKit (in the hook flow it is always
        // already running, so the running-app path is the norm; C1 covers not-running).
        AppFront.bringToFront(bundleID: Self.iTermBundleID)

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
