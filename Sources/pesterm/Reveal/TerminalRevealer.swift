import Foundation

/// A terminal that can be brought to focus on a notification click. Adding a new
/// terminal = one new conformance + a registry entry; core/notification/click-wiring
/// never change.
///
/// KEY INVARIANT: detect/reveal read the TERMINAL's env (e.g. ITERM_SESSION_ID),
/// NEVER the agent payload. The hook runs as a child of the agent in that tab, so it
/// inherits the terminal env — keeping reveal fully agent-agnostic.
protocol TerminalRevealer {
    /// Return a revealer if `env` identifies this terminal, else nil.
    static func detect(_ env: [String: String]) -> TerminalRevealer?
    var capability: RevealCapability { get }
    /// In-process reveal: ScriptingBridge/AppKit. CLI only as a last resort (none in v1).
    func reveal() throws

    /// Serialized reveal target, embedded in the notification's `userInfo` so a click
    /// delivered to ANY pesterm process (macOS routes a tap to one delegate per bundle id,
    /// not necessarily the posting process) can reveal the CLICKED notification's tab —
    /// not whatever tab the receiving process happened to capture. Same misrouting root
    /// cause as the permission decision handoff. Must include enough to reconstruct via
    /// `reveal(from:)` (a terminal tag + the session id).
    var revealUserInfo: [String: String] { get }

    /// Reconstruct a revealer from a `revealUserInfo` dict, or nil if this terminal does
    /// not recognize it (wrong/absent tag). Static so the registry can try each terminal.
    static func reveal(from userInfo: [String: String]) -> TerminalRevealer?

    // MARK: Focus probing (focus-aware notification deferral)

    /// Is THIS terminal's target session provably frontmost/focused right now?
    /// The detected instance already carries the identity captured from the ENV at
    /// detect time (session GUID / socket+pane / cwd) — never the agent payload.
    /// Anything less than a hard YES must be `.unverified` (fail toward posting).
    func probeFocus(frontmostBundleID: String?) -> FocusVerdict

    /// May a `.focused` verdict suppress a notification of `kind` for this terminal?
    /// A function (not a Set) so `NotificationKind` needs no Hashable conformance and
    /// a kind-specific gate (e.g. Ghostty info-only) is one line.
    func supportsFocusSuppression(for kind: NotificationKind) -> Bool
}

/// Fail-safe defaults: every conformance is a NO-OP prober until it opts in
/// explicitly — an unported terminal never suppresses, it always posts (the murky-case
/// fallback IS the old behavior, by construction).
extension TerminalRevealer {
    func probeFocus(frontmostBundleID: String?) -> FocusVerdict {
        return .unverified("no focus probe for this terminal")
    }

    func supportsFocusSuppression(for kind: NotificationKind) -> Bool {
        return false
    }
}
