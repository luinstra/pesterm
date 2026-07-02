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
///
/// Ghostty has no per-surface env var, so its key is the working directory — exactly as
/// fine-grained as its reveal target. Accepted collision: two same-directory sessions
/// coalesce into one card (the same case where reveal is already ambiguous); worktrees
/// avoid it, and the ghostty#11592 tty upgrade path removes it. With no PWD the key is
/// nil (post ungrouped): the failure direction is deliberately UNDER-coalescing, because
/// over-coalescing silently destroys other sessions' notifications (the shared-stale-GUID
/// bug class).
enum CoalescingKey {

    /// The key for this terminal context, or nil when the env identifies none (the
    /// request then posts without a group — no coalescing, same as before).
    static func fromEnv(_ env: [String: String]) -> String? {
        if let target = TmuxEnv.captureTarget(env: env) {
            return "tmux:\(target.socket):\(target.pane)"
        }
        // Gated on TERM_PROGRAM (the same GhosttyEnv gate as revealer detection), so a
        // stray/inherited ITERM_SESSION_ID can never hijack the key inside Ghostty.
        // No escaping is needed for ":" (or anything else) in the cwd: coalescing keys
        // are OPAQUE identifiers — compared for equality as whole strings, never parsed
        // back into components (the tmux key above already embeds colons). Two keys
        // collide only when the full strings are identical: the intended same-dir case.
        if let target = GhosttyEnv.captureTarget(env: env) {
            guard let cwd = target.cwd else { return nil }    // under-coalesce, never share a bucket
            return "ghostty:\(GhosttyEnv.normalizePath(cwd))" // normalized like chooseTerminal, so
        }                                                     // "/proj" vs "/proj/" never split cards
        guard let raw = env["ITERM_SESSION_ID"], !raw.isEmpty else { return nil }
        let guid = ITerm2Revealer.parseSessionId(raw)
        return guid.isEmpty ? nil : guid
    }
}
