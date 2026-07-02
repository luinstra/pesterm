import Foundation

/// PURE: the terminal-context key that suffixes an info notification's groupID (the
/// coalesce/replace identity). Mirrors revealer detection exactly: the SAME
/// `TmuxEnv.captureTarget` gate decides both, so the coalescing identity and the reveal
/// target can never disagree.
///
/// Why not always `ITERM_SESSION_ID`: inside tmux that value is the SHARED, STALE GUID
/// every pane inherited from the tmux server's first shell — keying on it coalesced
/// notifications from DIFFERENT panes (different Claude sessions) into one card, so pane
/// B's ping silently replaced pane A's. Inside tmux the key is socket+pane instead —
/// unique per pane, the same fields the reveal handoff already carries.
enum CoalescingKey {

    /// The key for this terminal context, or nil when the env identifies none (the
    /// request then posts without a group — no coalescing, same as before).
    static func fromEnv(_ env: [String: String]) -> String? {
        if let target = TmuxEnv.captureTarget(env: env) {
            return "tmux:\(target.socket):\(target.pane)"
        }
        guard let raw = env["ITERM_SESSION_ID"], !raw.isEmpty else { return nil }
        let guid = ITerm2Revealer.parseSessionId(raw)
        return guid.isEmpty ? nil : guid
    }
}
