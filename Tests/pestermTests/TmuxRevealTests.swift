import XCTest
import UserNotifications
@testable import pesterm

/// Pure cores + handoff for the tmux-aware revealer. The `tmux` subprocess (`TmuxClient`)
/// and the ObjC ScriptingBridge traversal are the impure shell — exercised by manual
/// in-tmux acceptance checks, not here.
final class TmuxRevealTests: XCTestCase {

    // MARK: TmuxEnv.socket(fromTMUX:)

    func testSocketFromTMUX() {
        XCTAssertEqual(TmuxEnv.socket(fromTMUX: "/private/tmp/tmux-501/default,12345,0"),
                       "/private/tmp/tmux-501/default")
        XCTAssertEqual(TmuxEnv.socket(fromTMUX: "/tmp/sock,1,0"), "/tmp/sock")
    }

    func testSocketFromTMUXRejectsBadInput() {
        XCTAssertNil(TmuxEnv.socket(fromTMUX: ""))
        XCTAssertNil(TmuxEnv.socket(fromTMUX: ",1,0"), "empty socket field → nil")
        XCTAssertNil(TmuxEnv.socket(fromTMUX: "nocommas"), "single-field (no comma) → nil")
    }

    // MARK: TmuxEnv.captureTarget(env:)

    func testCaptureTargetHappy() {
        let t = TmuxEnv.captureTarget(env: ["TMUX": "/s,1,0", "TMUX_PANE": "%3"])
        XCTAssertEqual(t?.socket, "/s")
        XCTAssertEqual(t?.pane, "%3")
    }

    func testCaptureTargetMissingPieces() {
        XCTAssertNil(TmuxEnv.captureTarget(env: ["TMUX": "/s,1,0"]), "no TMUX_PANE")
        XCTAssertNil(TmuxEnv.captureTarget(env: ["TMUX_PANE": "%3"]), "no TMUX")
        XCTAssertNil(TmuxEnv.captureTarget(env: ["TMUX": "/s,1,0", "TMUX_PANE": ""]), "empty pane")
        XCTAssertNil(TmuxEnv.captureTarget(env: [:]))
    }

    // MARK: parseClientTTYs / chooseClientTTY

    func testParseAndChooseOne() {
        let ttys = TmuxEnv.parseClientTTYs(listClientsOutput: "/dev/ttys003:0\n")
        XCTAssertEqual(ttys, ["/dev/ttys003"])
        XCTAssertEqual(TmuxEnv.chooseClientTTY(ttys), .one("/dev/ttys003"))
    }

    func testParseAndChooseDetached() {
        XCTAssertEqual(TmuxEnv.parseClientTTYs(listClientsOutput: ""), [])
        XCTAssertEqual(TmuxEnv.chooseClientTTY([]), .detached)
    }

    func testParseAndChooseMultiple() {
        let ttys = TmuxEnv.parseClientTTYs(listClientsOutput: "/dev/ttys003:0\n/dev/ttys005:0\n")
        XCTAssertEqual(ttys, ["/dev/ttys003", "/dev/ttys005"])
        XCTAssertEqual(TmuxEnv.chooseClientTTY(ttys), .multiple)
    }

    func testControlModeRowsDropped() {
        // A control-mode client (e.g. IDE integration) must never become the target.
        let ttys = TmuxEnv.parseClientTTYs(listClientsOutput: "/dev/ttys003:0\n/dev/ttys009:1\n")
        XCTAssertEqual(ttys, ["/dev/ttys003"])
        XCTAssertEqual(TmuxEnv.chooseClientTTY(ttys), .one("/dev/ttys003"))
    }

    func testOnlyControlModeIsDetached() {
        let ttys = TmuxEnv.parseClientTTYs(listClientsOutput: "/dev/ttys009:1\n")
        XCTAssertEqual(ttys, [])
        XCTAssertEqual(TmuxEnv.chooseClientTTY(ttys), .detached)
    }

    // MARK: normalizeTTY

    func testNormalizeTTY() {
        XCTAssertEqual(TmuxEnv.normalizeTTY("/dev/ttys003\n"), "/dev/ttys003")
        XCTAssertEqual(TmuxEnv.normalizeTTY("  /dev/ttys003  "), "/dev/ttys003")
        XCTAssertEqual(TmuxEnv.normalizeTTY("/dev/ttys003"), "/dev/ttys003", "idempotent")
    }

    // MARK: userInfo round-trip

    func testTmuxRevealUserInfoRoundTrips() {
        let r = TmuxRevealer(socket: "/s", pane: "%3")
        XCTAssertEqual(r.revealUserInfo, ["terminal": "tmux", "socket": "/s", "pane": "%3"])

        let rebuilt = RevealerRegistry.revealer(from: r.revealUserInfo)
        let tmux = rebuilt as? TmuxRevealer
        XCTAssertEqual(tmux?.socket, "/s")
        XCTAssertEqual(tmux?.pane, "%3")
    }

    func testTmuxReconstructRejectsMissingFields() {
        XCTAssertNil(RevealerRegistry.revealer(from: ["terminal": "tmux", "socket": "/s"]), "no pane")
        XCTAssertNil(RevealerRegistry.revealer(from: ["terminal": "tmux", "pane": "%3"]), "no socket")
        XCTAssertNil(RevealerRegistry.revealer(from: ["terminal": "tmux", "socket": "", "pane": "%3"]))
    }

    func testTagIsolationBetweenRevealers() {
        let tmuxDict = ["terminal": "tmux", "socket": "/s", "pane": "%3"]
        let itermDict = ["terminal": "iterm2", "session": "GUID"]
        XCTAssertNil(ITerm2Revealer.reveal(from: tmuxDict), "iterm must reject a tmux dict")
        XCTAssertNil(TmuxRevealer.reveal(from: itermDict), "tmux must reject an iterm dict")
    }

    // MARK: registry precedence — tmux beats stale ITERM_SESSION_ID

    func testTmuxDetectedBeforeITermWhenInTmux() {
        let env = [
            "TMUX": "/s,1,0", "TMUX_PANE": "%3",
            "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:STALEGUID"
        ]
        XCTAssertTrue(RevealerRegistry.detect(env) is TmuxRevealer,
                      "inside tmux the tmux revealer must win over a stale ITERM_SESSION_ID")
    }

    func testITermDetectedWhenNotInTmux() {
        let env = ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:GUID"]
        XCTAssertTrue(RevealerRegistry.detect(env) is ITerm2Revealer)
    }

    // MARK: launcher probe list

    func testSearchPathsCoverHomebrewMacPortsAndSystem() {
        XCTAssertTrue(TmuxClient.searchPaths.contains("/opt/local/bin/tmux"), "MacPorts")
        XCTAssertTrue(TmuxClient.searchPaths.contains("/opt/homebrew/bin/tmux"))
        XCTAssertEqual(TmuxClient.searchPaths.last, "/usr/bin/tmux",
                       "system tmux is the last resort")
    }

    // MARK: failureDiagnostic — every failure branch fronts NOTHING (D5)

    // Since the reveal-time reorder, iTerm is fronted only AFTER a verified
    // attached-client tty match. Every failure branch therefore ends in
    // "no reveal performed" — the old "revealed app only" suffix would be a lie.

    func testFailureDiagnosticsAllEndInNoRevealPerformed() {
        let all: [TmuxRevealer.RevealFailure] = [
            .tmuxNotFound,
            .detached,
            .multiple,
            .queryFailed,
            .byTtyMiss(tty: "/dev/ttys003", grant: .granted),
            .byTtyMiss(tty: "/dev/ttys003", grant: .denied),
        ]
        for failure in all {
            let s = TmuxRevealer.failureDiagnostic(failure, pane: "%3")
            XCTAssertTrue(s.hasSuffix("no reveal performed"),
                          "nothing was fronted — the copy must say so: \(s)")
        }
    }

    func testFailureDiagnosticTmuxNotFound() {
        XCTAssertEqual(TmuxRevealer.failureDiagnostic(.tmuxNotFound, pane: "%3"),
                       "tmux not found; no reveal performed")
    }

    func testFailureDiagnosticDetachedNotesITermOnly() {
        let s = TmuxRevealer.failureDiagnostic(.detached, pane: "%3")
        XCTAssertTrue(s.contains("%3"))
        XCTAssertTrue(s.contains("detached"))
        XCTAssertTrue(s.contains("iTerm-only"),
                      "tmux reveal is iTerm-only — the copy must say so")
    }

    func testFailureDiagnosticMultiple() {
        let s = TmuxRevealer.failureDiagnostic(.multiple, pane: "%3")
        XCTAssertTrue(s.contains("multiple tmux clients"))
        XCTAssertTrue(s.contains("%3"))
    }

    func testFailureDiagnosticQueryFailed() {
        let s = TmuxRevealer.failureDiagnostic(.queryFailed, pane: "%3")
        XCTAssertTrue(s.contains("tmux query failed"))
        XCTAssertTrue(s.contains("%3"))
    }

    func testByTtyMissWithGrantBlamesTheClientNotTheGrant() {
        // Grant fine + no iTerm session matched the client tty: the likeliest cause is
        // a client attached from a NON-iTerm terminal (e.g. tmux under Ghostty).
        let s = TmuxRevealer.failureDiagnostic(
            .byTtyMiss(tty: "/dev/ttys003", grant: .granted), pane: "%3")
        XCTAssertTrue(s.contains("/dev/ttys003"))
        XCTAssertTrue(s.contains("may not be attached from iTerm"),
                      "the client may live in another terminal app — say so")
        XCTAssertFalse(s.contains("Automation"),
                       "grant is fine — don't send the user to System Settings")
    }

    func testByTtyMissWithoutGrantBlamesTheGrant() {
        for grant in [AutomationGrant.State.denied, .needsPrompt] {
            let s = TmuxRevealer.failureDiagnostic(
                .byTtyMiss(tty: "/dev/ttys003", grant: grant), pane: "%3")
            XCTAssertTrue(s.contains("Automation") || s.contains("automation"),
                          "missing grant must be named — this failure was silent for weeks")
        }
    }

    // MARK: makeContent embedding (the userInfo reaches the notification)

    func testTmuxTargetEmbeddedInNotificationUserInfo() {
        let req = NotificationRequest(title: "t", body: "b",
                                      revealUserInfo: ["terminal": "tmux", "socket": "/s", "pane": "%3"])
        let content = UNUserNotificationBackend.makeContent(from: req)
        XCTAssertEqual(content.userInfo["terminal"] as? String, "tmux")
        XCTAssertEqual(content.userInfo["socket"] as? String, "/s")
        XCTAssertEqual(content.userInfo["pane"] as? String, "%3")
    }
}
