import Foundation

/// The outcome of feeding an agent's hook JSON to an adapter: either a request to POST, or
/// a SUPPRESSION carrying the diagnostic line the caller writes to stderr before exit 0.
/// (An UNKNOWN adapter value is modeled by `AdapterRegistry.adapter(for:)` returning nil —
/// the caller exits 2 — so it is not a case here.)
enum AdapterOutcome {
    case post(NotificationRequest)
    case suppress(String)
}

/// One agent hook entry point, selected by the `--adapter <value>` flag.
///
/// Conformances are PURE: they parse stdin and return an `AdapterOutcome` with no I/O of
/// their own — the caller (main.swift) owns the stderr write + exit. Adding an agent is a
/// new conformance + one line in `AdapterRegistry`, with NO edit to main.swift's dispatch.
/// This is the agent-axis mirror of `TerminalRevealer` / `RevealerRegistry` on the reveal
/// axis: the runtime path is genuinely additive, not a hardcoded switch.
protocol AgentAdapter {
    /// The `--adapter` value that selects this adapter (e.g. "claude", "claude-permission").
    static var adapterValue: String { get }

    /// Whether this adapter posts an info notification or a blocking permission request.
    static var kind: NotificationKind { get }

    /// PURE: map the hook JSON on `stdin` to an outcome. `iTermSessionId` is the
    /// env-derived reveal/coalescing key (NEVER the payload's session id). `soundOverride`
    /// (from `--sound`) applies to info adapters; permission adapters ignore it.
    static func outcome(stdin: Data, iTermSessionId: String?,
                        soundOverride: String?) -> AdapterOutcome
}
