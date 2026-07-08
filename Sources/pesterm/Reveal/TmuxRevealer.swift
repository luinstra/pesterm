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
        let resolution = Self.resolveClientChoice(clients)
        Trace.log("TMUX_REVEAL clientResolution=\(String(describing: resolution)) of \(clients.count)")

        switch resolution {
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
        case .remoteOnly:
            // Clients exist, none locally revealable — a distinct story from a
            // genuinely detached session; name the invisible culprit (mosh/ssh).
            warn(Self.failureDiagnostic(.remoteOnly, pane: pane))
        }
    }

    /// IMPURE, thin: classify each client's pid via `ProcessAncestry`/`TerminalHost` —
    /// but only when there is more than one client (the single-client path never
    /// classified before; matching today's cost profile) — and delegate every decision
    /// to the pure `TmuxEnv.resolveClients`. Shared by `reveal()` and the focus probe,
    /// so the reveal-path diagnostics and the probe verdicts can never diverge on the
    /// same input.
    static func resolveClientChoice(_ clients: [TmuxEnv.Client]) -> TmuxEnv.ClientResolution {
        let classified: [(client: TmuxEnv.Client, locallyHosted: Bool)]
        if clients.count > 1 {
            classified = clients.map { c in
                let hosted = c.pid.map {
                    TerminalHost.classify(
                        executablePaths: ProcessAncestry.executablePaths(startingAt: $0)) != nil
                } ?? false
                return (c, hosted)
            }
        } else {
            // 0 or 1 client: resolveClients never filters these, so skip the
            // (subprocess-y) ancestry classification entirely.
            classified = clients.map { ($0, false) }
        }
        return TmuxEnv.resolveClients(classified)
    }

    // MARK: - Focus probe (focus-aware notification deferral)

    /// The probe's impure edges, injectable for orchestration tests (D3 seam). Every
    /// default is the production implementation; tests swap closures to assert the
    /// step wiring without tmux, TCC, or ScriptingBridge.
    struct FocusProbeDeps {
        var grantCheck: () -> AutomationGrant.State = AutomationGrant.checkITerm
        var locateLauncher: () -> TmuxClient.Launcher? = TmuxClient.locateLauncher
        var attachedClients: (TmuxClient.Launcher, String, String, TimeInterval) -> [TmuxEnv.Client]? = {
            TmuxClient.attachedClients(launcher: $0, socket: $1, pane: $2, timeout: $3)
        }
        var resolveClients: ([TmuxEnv.Client]) -> TmuxEnv.ClientResolution =
            TmuxRevealer.resolveClientChoice
        var paneIsActive: (TmuxClient.Launcher, String, String, TimeInterval) -> Bool? = {
            TmuxClient.paneIsActive(launcher: $0, socket: $1, pane: $2, timeout: $3)
        }
        var readValue: (String, TimeInterval) -> String? = FocusProbeClient.readValue
    }

    /// Both kinds are suppressible: a hard YES requires the pane active in tmux AND
    /// the client's tty fronted in iTerm — an exact, two-sided match.
    func supportsFocusSuppression(for kind: NotificationKind) -> Bool {
        return true
    }

    /// Protocol entry point — production deps.
    func probeFocus(frontmostBundleID: String?) -> FocusVerdict {
        return probeFocus(frontmostBundleID: frontmostBundleID, deps: FocusProbeDeps())
    }

    /// Steps in cost order; EVERY miss → `.unverified(reason)` (fail toward posting).
    /// Hard YES requires (a) tmux-side: the target pane is the active pane of the
    /// active window, AND the session has exactly one locally-hosted attached client;
    /// (b) host-side: that client's tty equals the tty of iTerm's frontmost window's
    /// current session. Unverified reasons are Trace-logged HERE (D3) — they never
    /// ride through `FocusAction`.
    func probeFocus(frontmostBundleID: String?, deps: FocusProbeDeps) -> FocusVerdict {
        // Step 1: the probe is iTerm-only — the same precision ceiling as the
        // exact-tab reveal (other hosts expose no tty; ghostty#11592). tmux under
        // Ghostty/Terminal.app stays on today's always-post path by design.
        guard FocusPolicy.hostIsFrontmost(expectedBundleID: ITerm2Revealer.iTermBundleID,
                                          frontmostBundleID: frontmostBundleID) else {
            Trace.log("FOCUS_PROBE_TMUX tier0=miss frontmost=\(frontmostBundleID ?? "<nil>")")
            return .unverified("iTerm2 not frontmost (tmux focus probe is iTerm-only)")
        }

        // Step 2 (D7): inside tmux pesterm is NOT an iTerm descendant (the tmux server
        // is a launchd daemon), so the host-side read needs the same Automation grant
        // the tmux reveal already needs. Anything but .granted → post, and the probe
        // child is NOT spawned — a background probe must never pop a consent dialog
        // (askUserIfNeeded is false in the check; the prompt still appears naturally
        // on the first tmux reveal).
        let grant = deps.grantCheck()
        guard grant == .granted else {
            Trace.log("FOCUS_PROBE_TMUX grant=\(grant)")
            return .unverified("iTerm automation grant not granted")
        }

        // Step 3: exactly one locally-hosted attached client, via the SAME resolution
        // rule the reveal path uses (0.4s tmux CLI box — probe budget, not the reveal
        // path's 1.5s).
        guard let launcher = deps.locateLauncher() else {
            Trace.log("FOCUS_PROBE_TMUX launcher=nil")
            return .unverified("tmux not found")
        }
        guard let clients = deps.attachedClients(launcher, socket, pane, 0.4) else {
            Trace.log("FOCUS_PROBE_TMUX clients=queryFailed")
            return .unverified("tmux client query failed")
        }
        let client: TmuxEnv.Client
        switch deps.resolveClients(clients) {
        case .one(let c):
            client = c
        case .remoteOnly:
            Trace.log("FOCUS_PROBE_TMUX clientResolution=remoteOnly")
            return .unverified("attached clients are remote-only")
        case .multiple:
            Trace.log("FOCUS_PROBE_TMUX clientResolution=multiple")
            return .unverified("multiple locally-hosted clients")
        case .detached:
            Trace.log("FOCUS_PROBE_TMUX clientResolution=detached")
            return .unverified("no attached tmux client")
        }

        // Step 4 (a, tmux-side): the target pane must be the active pane of the
        // active window (list-clients already scoped the client to the pane's
        // SESSION — see TmuxClient.attachedClients).
        guard deps.paneIsActive(launcher, socket, pane, 0.4) == true else {
            Trace.log("FOCUS_PROBE_TMUX paneActive=0")
            return .unverified("target pane not active")
        }

        // Step 5 (b, host-side): iTerm's frontmost window's current session tty must
        // equal the attached client's tty (read in the disposable probe child,
        // 0.5s box; normalized on both sides).
        guard let frontTty = deps.readValue("iterm-session-tty", 0.5) else {
            Trace.log("FOCUS_PROBE_TMUX ttyRead=nil")
            return .unverified("probe timeout/empty")
        }
        guard TmuxEnv.normalizeTTY(frontTty) == TmuxEnv.normalizeTTY(client.tty) else {
            Trace.log("FOCUS_PROBE_TMUX paneActive=1 ttyMatch=0 front=\(frontTty) client=\(client.tty)")
            return .unverified("iTerm is fronting a different session")
        }
        Trace.log("FOCUS_PROBE_TMUX paneActive=1 ttyMatch=1 verdict=focused")
        return .focused
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
