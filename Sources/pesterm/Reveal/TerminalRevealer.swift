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
}
