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

        guard let clients = TmuxClient.attachedClients(launcher: launcher, socket: socket,
                                                       pane: pane) else {
            warn(Self.failureDiagnostic(.queryFailed, pane: pane))
            return
        }
        var choice = TmuxEnv.chooseClient(clients)
        Trace.log("TMUX_REVEAL clientChoice=\(String(describing: choice)) of \(clients.count)")

        if case .multiple = choice {
            // Remote-attach filter: a mosh/ssh-hosted client (or one in an unsupported
            // terminal) cannot be revealed locally — dropping it is logic, not
            // preference. The recurring real-world case: a forgotten mosh attach
            // sharing the session with the real terminal tab.
            let classified: [(client: TmuxEnv.Client, locallyHosted: Bool)] = clients.map { c in
                let hosted = c.pid.map {
                    TerminalHost.classify(
                        executablePaths: ProcessAncestry.executablePaths(startingAt: $0)) != nil
                } ?? false
                return (c, hosted)
            }
            choice = TmuxEnv.chooseLocalClient(classified)
            Trace.log("TMUX_REVEAL localFilter \(clients.count) -> \(String(describing: choice))")
            if case .detached = choice {
                // Clients exist, none locally revealable — a distinct story from a
                // genuinely detached session; name the invisible culprit.
                warn(Self.failureDiagnostic(.remoteOnly, pane: pane))
                return
            }
        }

        switch choice {
        case .one(let client):
            let found = pesterm_reveal_iterm_session_by_tty(client.tty, ITerm2Revealer.iTermBundleID)
            Trace.log("TMUX_REVEAL byTty tty=\(client.tty) found=\(found)")
            if found {
                // The client provably lives in an iTerm session — fronting is justified,
                // and the exact tab is selected (the full-precision tier).
                AppFront.bringToFront(bundleID: ITerm2Revealer.iTermBundleID)
                Trace.log("TMUX_REVEAL fronted iTerm socket=\(socket) pane=\(pane)")
                let snapped = TmuxClient.selectPane(launcher: launcher, socket: socket, pane: pane)
                Trace.log("TMUX_REVEAL selectPane=\(snapped)")
                if !snapped {
                    warn("tmux snap to pane \(pane) failed (pane may have closed); revealed tab only")
                }
            } else if let pid = client.pid,
                      let host = TerminalHost.classify(
                          executablePaths: ProcessAncestry.executablePaths(startingAt: pid)) {
                // Tier 2: no iTerm session owns that tty, but the client's process
                // ancestry names its host app — still EVIDENCE, not a guess. Front the
                // host and snap the pane inside tmux (the attached client displays it).
                // Exact-tab selection within the host stays iTerm-only until other
                // terminals expose a tty (ghostty#11592).
                AppFront.bringToFront(bundleID: host.bundleID)
                let snapped = TmuxClient.selectPane(launcher: launcher, socket: socket, pane: pane)
                Trace.log("TMUX_REVEAL frontedHost app=\(host.appName) pid=\(pid) selectPane=\(snapped)")
                let iTermGrant = host.bundleID == ITerm2Revealer.iTermBundleID
                    ? AutomationGrant.checkITerm() : nil
                warn(Self.hostedFrontDiagnostic(appName: host.appName, pane: pane,
                                                iTermGrant: iTermGrant))
            } else {
                // No tty match AND no classifiable host — front nothing (never guess).
                // A missing Automation grant makes the iTerm traversal see ZERO windows —
                // the most common cause of this miss under tmux-in-iTerm, and invisible
                // without the check. Blame the grant only when it is the problem.
                let grant = AutomationGrant.checkITerm()
                Trace.log("TMUX_REVEAL byTtyMiss grant=\(grant) pid=\(client.pid.map(String.init) ?? "nil")")
                warn(Self.failureDiagnostic(.byTtyMiss(tty: client.tty, grant: grant), pane: pane))
            }
        case .detached:
            warn(Self.failureDiagnostic(.detached, pane: pane))
        case .multiple:
            warn(Self.failureDiagnostic(.multiple, pane: pane))
        }
    }

    /// The reveal's failure branches — every one fronts NOTHING (we cannot know which
    /// app owns the tmux client; fronting iTerm on a guess was the bug D5 fixed).
    enum RevealFailure: Equatable {
        case tmuxNotFound
        case detached
        /// Two+ LOCALLY-HOSTED clients remain after the remote-attach filter —
        /// genuine ambiguity between real displays.
        case multiple
        /// Clients are attached, but none is hosted by a local terminal app pesterm
        /// can reveal (mosh/ssh attaches, unsupported terminals).
        case remoteOnly
        case queryFailed
        /// Attached client tty found, but no iTerm session matched it.
        case byTtyMiss(tty: String, grant: AutomationGrant.State)
    }

    /// PURE: the tier-2 hosted-front diagnostic — the tty didn't match an iTerm session
    /// but ancestry identified the client's host app, which was fronted and the pane
    /// snapped. Truthful about the precision ceiling (exact-tab under tmux is iTerm-only
    /// until other terminals expose a tty). When the host IS iTerm yet the tty match
    /// missed, the Automation grant is the prime suspect — name it (same silent-failure
    /// trap as ever).
    static func hostedFrontDiagnostic(appName: String, pane: String,
                                      iTermGrant: AutomationGrant.State?) -> String {
        var msg = "fronted \(appName) (the tmux client's host app) and snapped pane \(pane)"
                + " — exact-tab selection under tmux is iTerm-only"
        if let grant = iTermGrant, grant != .granted {
            msg += "; iTerm automation " + AutomationGrant.describe(grant, appName: "iTerm2")
        }
        return msg
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
            return "multiple locally-hosted tmux clients for pane \(pane); no reveal performed"
        case .remoteOnly:
            return "attached tmux clients for pane \(pane) are all remote or unsupported "
                 + "(a mosh/ssh attach can't be revealed locally); no reveal performed"
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
