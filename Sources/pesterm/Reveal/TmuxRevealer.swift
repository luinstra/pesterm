import Foundation
import CITermBridge

/// Reveals the right iTerm2 tab + tmux pane when a notification was posted from inside tmux.
///
/// Inside tmux, `ITERM_SESSION_ID` is stale/shared (tmux decouples the shell from the iTerm
/// session), so the iTerm-by-GUID reveal lands on the wrong/closed tab. Instead we resolve
/// LIVE at click time: query the tmux server for the currently-attached client's tty, front
/// the iTerm session whose tty matches, then `select-window`/`select-pane` to snap onto the
/// exact pane. The tmux socket + pane ride in the notification userInfo, so this works even
/// from the relaunch/responder process (which has no `$TMUX`): `tmux -S <socket>` needs no env.
///
/// Registered BEFORE `ITerm2Revealer` so it wins detection inside tmux (where a stale
/// `ITERM_SESSION_ID` is also present). Every failure degrades to "front iTerm + stderr" —
/// identical to the existing stale-session miss, never worse.
final class TmuxRevealer: TerminalRevealer {

    /// Terminal tag in the reveal-target userInfo handoff.
    static let terminalTag = "tmux"

    /// tmux socket path (field 0 of `$TMUX`) and the originating pane id (`$TMUX_PANE`).
    let socket: String
    let pane: String

    /// `.precise` — snap-to-pane lands on the exact pane (capability is metadata only;
    /// nothing consumes it yet).
    var capability: RevealCapability { .precise }

    init(socket: String, pane: String) {
        self.socket = socket
        self.pane = pane
    }

    // MARK: - Reveal-target handoff (rides in the notification userInfo)

    /// Socket + pane are self-sufficient: any process can run `tmux -S <socket>` without
    /// `$TMUX`. No iTerm GUID/tty is embedded — the attached tab is resolved LIVE at click
    /// time so detach/reattach to a different window still reveals correctly.
    var revealUserInfo: [String: String] {
        ["terminal": Self.terminalTag, "socket": socket, "pane": pane]
    }

    /// Reconstruct from a userInfo dict, or nil if it isn't ours (tag mismatch / missing
    /// socket or pane).
    static func reveal(from userInfo: [String: String]) -> TerminalRevealer? {
        guard userInfo["terminal"] == terminalTag,
              let socket = userInfo["socket"], !socket.isEmpty,
              let pane = userInfo["pane"], !pane.isEmpty else { return nil }
        return TmuxRevealer(socket: socket, pane: pane)
    }

    // MARK: - Detection

    /// An instance iff `$TMUX` parses to a socket AND `$TMUX_PANE` is present. Otherwise nil
    /// → the registry falls through to `ITerm2Revealer` (non-tmux path unchanged).
    static func detect(_ env: [String: String]) -> TerminalRevealer? {
        guard let target = TmuxEnv.captureTarget(env: env) else { return nil }
        return TmuxRevealer(socket: target.socket, pane: target.pane)
    }

    // MARK: - Reveal

    func reveal() throws {
        // Always front iTerm first (best-effort, like the iTerm path) so even a fallback
        // lands the user on iTerm.
        ITermFront.bringToFront(bundleID: ITerm2Revealer.iTermBundleID)

        guard let launcher = TmuxClient.locateLauncher() else {
            warn("tmux not found; revealed iTerm app only")
            return
        }

        switch TmuxClient.attachedClientTTY(launcher: launcher, socket: socket, pane: pane) {
        case .one(let tty):
            if pesterm_reveal_iterm_session_by_tty(tty, ITerm2Revealer.iTermBundleID) {
                // Tab fronted — now snap onto the originating pane.
                if !TmuxClient.selectPane(launcher: launcher, socket: socket, pane: pane) {
                    warn("tmux snap to pane \(pane) failed (pane may have closed); revealed tab only")
                }
            } else {
                warn("no iTerm tab for tmux client tty \(tty); revealed app only")
            }
        case .detached:
            warn("no attached tmux client for pane \(pane) (detached?); revealed app only")
        case .multiple:
            warn("multiple tmux clients for pane \(pane); revealed app only")
        case nil:
            warn("tmux query failed for pane \(pane); revealed app only")
        }
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("pesterm: \(message)\n".utf8))
    }
}
