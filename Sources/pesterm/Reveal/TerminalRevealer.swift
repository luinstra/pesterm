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
}
