import Foundation
import CGhosttyBridge

/// Reveals the right Ghostty tab when a notification was posted from inside Ghostty.
///
/// Ghostty sets no per-surface env var (no TERM_SESSION_ID equivalent) and its
/// AppleScript terminal class exposes no tty/pid, so the reveal key is the WORKING
/// DIRECTORY: `$PWD` captured from the terminal env at detect time, matched at click
/// time against each terminal's `working directory` (Ghostty ≥ 1.3 AppleScript,
/// preview API). Exactly one match → activate window + select tab + focus; zero or
/// many → the app is already fronted, stderr says why (one-or-fallback, never guess —
/// same discipline as the tmux revealer). Two surfaces in the same directory are
/// therefore ambiguous by design (documented; self-heals if ghostty#11592 lands a tty
/// property, at which point the match key upgrades to the hook's controlling tty).
///
/// The reliable layer is `.appOnly` (front com.mitchellh.ghostty); the precise
/// cwd-match layer sits on top and degrades onto it on EVERY failure: missing
/// Automation grant, `macos-applescript = false`, Ghostty < 1.3, ambiguous cwd,
/// closed tab.
final class GhosttyRevealer: TerminalRevealer {

    /// Terminal tag in the reveal-target userInfo handoff.
    static let terminalTag = "ghostty"

    /// Ghostty bundle id (SBApplication + NSRunningApplication + TCC target).
    static let ghosttyBundleID = "com.mitchellh.ghostty"

    /// `$PWD` captured from the terminal env at detect time; nil → app-only reveal
    /// (Ghostty detected but no cwd to match — better to front the right APP than
    /// nothing at all).
    let cwd: String?

    /// First revealer whose capability varies: `.precise` only when a cwd was captured.
    /// Still metadata-only — nothing consumes it yet.
    var capability: RevealCapability { cwd != nil ? .precise : .appOnly }

    init(cwd: String?) {
        self.cwd = cwd
    }

    // MARK: - Reveal-target handoff (rides in the notification userInfo)

    /// The dict is self-sufficient (like tmux's socket+pane): the relaunch-responder
    /// process has no terminal env at all, so everything the reveal needs must ride
    /// here. App-only targets simply omit the cwd.
    var revealUserInfo: [String: String] {
        var info = ["terminal": Self.terminalTag]
        if let cwd = cwd {
            info["cwd"] = cwd
        }
        return info
    }

    /// Reconstruct from a userInfo dict, or nil if it isn't ours (tag mismatch). A
    /// missing/empty cwd is a VALID app-only target, not a rejection — Ghostty is the
    /// one terminal whose handoff can legitimately carry no precise key.
    static func reveal(from userInfo: [String: String]) -> TerminalRevealer? {
        guard userInfo["terminal"] == terminalTag else { return nil }
        let cwd = userInfo["cwd"].flatMap { $0.isEmpty ? nil : $0 }
        return GhosttyRevealer(cwd: cwd)
    }

    // MARK: - Detection

    /// An instance iff `TERM_PROGRAM == "ghostty"` (the same `GhosttyEnv.captureTarget`
    /// gate that decides the coalescing key — the two can never disagree).
    static func detect(_ env: [String: String]) -> TerminalRevealer? {
        guard let target = GhosttyEnv.captureTarget(env: env) else { return nil }
        return GhosttyRevealer(cwd: target.cwd)
    }

    // MARK: - Reveal

    func reveal() throws {
        // Always front the app first — the reliable layer every failure degrades onto.
        AppFront.bringToFront(bundleID: Self.ghosttyBundleID)
        Trace.log("GHOSTTY_REVEAL fronted app cwd=\(cwd ?? "<none>")")

        guard let cwd = cwd else {
            Trace.log("GHOSTTY_REVEAL appOnly (no cwd captured)")
            return
        }

        // Enumerate live terminals via the ObjC bridge (an empty list covers app not
        // scriptable, grant missing, and macos-applescript=false alike) and let the
        // pure layer decide.
        let entries = pesterm_ghostty_list_terminals(Self.ghosttyBundleID) ?? []
        let candidates: [GhosttyEnv.Candidate] = entries.compactMap { entry in
            guard let windowId = entry["windowId"] as? String,
                  let tabId = entry["tabId"] as? String,
                  let terminalId = entry["terminalId"] as? String else { return nil }
            return GhosttyEnv.Candidate(
                identity: GhosttyEnv.TerminalIdentity(windowId: windowId, tabId: tabId,
                                                      terminalId: terminalId),
                cwd: entry["cwd"] as? String ?? "")
        }

        let choice = GhosttyEnv.chooseTerminal(matching: cwd, candidates: candidates)
        Trace.log("GHOSTTY_REVEAL candidates=\(candidates.count) choice=\(String(describing: choice))")

        switch choice {
        case .one(let identity):
            let focused = pesterm_ghostty_focus_terminal(
                identity.windowId, identity.tabId, identity.terminalId, Self.ghosttyBundleID)
            Trace.log("GHOSTTY_REVEAL focus terminal=\(identity.terminalId) focused=\(focused)")
            if !focused {
                warn("Ghostty terminal in \(cwd) closed before focus; revealed app only")
            }
        case .noMatch, .multiple:
            // A missing Automation grant makes the traversal see ZERO windows — the
            // same silent-failure trap the tmux path hit. Blame the grant only when
            // the grant is actually the problem.
            let grant = AutomationGrant.checkGhostty()
            Trace.log("GHOSTTY_REVEAL miss choice=\(String(describing: choice)) grant=\(grant)")
            warn(GhosttyEnv.missDiagnostic(choice: choice, cwd: cwd, grant: grant))
        }
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("pesterm: \(message)\n".utf8))
    }
}
