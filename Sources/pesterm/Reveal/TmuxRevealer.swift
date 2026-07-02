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
/// `ITERM_SESSION_ID` is also present). Fronting follows evidence: a verified match
/// fronts iTerm; every failure degrades to stderr only — never front an app on a guess
/// (the tmux server may be hosted by Ghostty/Terminal.app, where fronting iTerm is
/// actively the wrong app).
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
        // Fronting follows evidence: query FIRST, front only after the attached client
        // provably lives in an iTerm session. The old shape fronted iTerm before knowing
        // anything — actively the wrong app when the tmux server is hosted by
        // Ghostty/Terminal.app. ScriptingBridge `select` works on a non-frontmost app,
        // so select-then-activate is equivalent to the old activate-then-select.
        guard let launcher = TmuxClient.locateLauncher() else {
            Trace.log("TMUX_REVEAL launcher=nil")
            warn(Self.failureDiagnostic(.tmuxNotFound, pane: pane))
            return
        }
        Trace.log("TMUX_REVEAL launcher=\(launcher.exe) prefix=\(launcher.prefixArgs)")

        let choice = TmuxClient.attachedClientTTY(launcher: launcher, socket: socket, pane: pane)
        Trace.log("TMUX_REVEAL clientChoice=\(String(describing: choice))")
        switch choice {
        case .one(let tty):
            let found = pesterm_reveal_iterm_session_by_tty(tty, ITerm2Revealer.iTermBundleID)
            Trace.log("TMUX_REVEAL byTty tty=\(tty) found=\(found)")
            if found {
                // The client provably lives in an iTerm session — fronting is justified.
                AppFront.bringToFront(bundleID: ITerm2Revealer.iTermBundleID)
                Trace.log("TMUX_REVEAL fronted iTerm socket=\(socket) pane=\(pane)")
                let snapped = TmuxClient.selectPane(launcher: launcher, socket: socket, pane: pane)
                Trace.log("TMUX_REVEAL selectPane=\(snapped)")
                if !snapped {
                    warn("tmux snap to pane \(pane) failed (pane may have closed); revealed tab only")
                }
            } else {
                // A missing Automation grant makes the traversal see ZERO windows — the
                // most common cause of this miss under tmux, and invisible without the
                // check (the symptom reads as "no matching tab"). Blame the grant only
                // when the grant is actually the problem.
                let grant = AutomationGrant.checkITerm()
                Trace.log("TMUX_REVEAL byTtyMiss grant=\(grant)")
                warn(Self.failureDiagnostic(.byTtyMiss(tty: tty, grant: grant), pane: pane))
            }
        case .detached:
            warn(Self.failureDiagnostic(.detached, pane: pane))
        case .multiple:
            warn(Self.failureDiagnostic(.multiple, pane: pane))
        case nil:
            warn(Self.failureDiagnostic(.queryFailed, pane: pane))
        }
    }

    /// The reveal's failure branches — every one fronts NOTHING (we cannot know which
    /// app owns the tmux client; fronting iTerm on a guess was the bug D5 fixed).
    enum RevealFailure: Equatable {
        case tmuxNotFound
        case detached
        case multiple
        case queryFailed
        /// Attached client tty found, but no iTerm session matched it.
        case byTtyMiss(tty: String, grant: AutomationGrant.State)
    }

    /// PURE: one diagnostic per failure branch. All end in "no reveal performed" — since
    /// the D5 reorder nothing is fronted on failure, so the old "revealed app only"
    /// suffix would be a lie. The by-tty-miss/detached variants note that the client may
    /// not be attached from iTerm at all (tmux reveal is iTerm-only); with the grant
    /// missing, the message must name it — that exact failure was silent and
    /// misattributed before (iTerm fronts, no tab switch, no hint why).
    static func failureDiagnostic(_ failure: RevealFailure, pane: String) -> String {
        switch failure {
        case .tmuxNotFound:
            return "tmux not found; no reveal performed"
        case .detached:
            return "no attached tmux client for pane \(pane) (detached? note tmux reveal "
                 + "is iTerm-only); no reveal performed"
        case .multiple:
            return "multiple tmux clients for pane \(pane); no reveal performed"
        case .queryFailed:
            return "tmux query failed for pane \(pane); no reveal performed"
        case .byTtyMiss(let tty, let grant):
            switch grant {
            case .granted:
                return "no iTerm tab for tmux client tty \(tty) — the client may not be "
                     + "attached from iTerm (tmux reveal is iTerm-only); no reveal performed"
            default:
                return "tmux reveal blocked — iTerm automation "
                     + AutomationGrant.describe(grant, appName: "iTerm2")
                     + "; no reveal performed"
            }
        }
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("pesterm: \(message)\n".utf8))
    }
}
