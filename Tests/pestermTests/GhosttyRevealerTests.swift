import XCTest
@testable import pesterm

/// Detection, capability tiers, and the userInfo handoff for the Ghostty revealer. The
/// impure reveal (AppFront + CGhosttyBridge) is covered by manual acceptance checks.
final class GhosttyRevealerTests: XCTestCase {

    // MARK: detect matrix

    func testDetectInsideGhosttyWithPWD() {
        let env = ["TERM_PROGRAM": "ghostty", "PWD": "/proj"]
        let revealer = RevealerRegistry.detect(env)
        XCTAssertTrue(revealer is GhosttyRevealer)
        XCTAssertEqual((revealer as? GhosttyRevealer)?.cwd, "/proj")
        XCTAssertEqual(revealer?.capability, .precise)
    }

    func testDetectInsideGhosttyWithoutPWDIsAppOnly() {
        // No per-surface env var exists in Ghostty; without PWD the revealer still
        // detects (fronting the right APP beats no reveal) but degrades to .appOnly.
        for env in [["TERM_PROGRAM": "ghostty"],
                    ["TERM_PROGRAM": "ghostty", "PWD": ""]] {
            let revealer = RevealerRegistry.detect(env)
            XCTAssertTrue(revealer is GhosttyRevealer)
            XCTAssertNil((revealer as? GhosttyRevealer)?.cwd)
            XCTAssertEqual(revealer?.capability, .appOnly)
        }
    }

    func testDetectITermEnvStaysITerm() {
        let env = ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:G", "PWD": "/p"]
        XCTAssertTrue(RevealerRegistry.detect(env) is ITerm2Revealer)
    }

    func testDetectNotGhosttyInsideTmux() {
        // tmux panes set TERM_PROGRAM=tmux, so Ghostty never detects there — the tmux
        // revealer owns that env (tmux reveal stays iTerm-only, documented).
        XCTAssertNil(GhosttyRevealer.detect(["TERM_PROGRAM": "tmux", "PWD": "/p"]))
    }

    // MARK: synthetic registry-order pin

    func testTmuxStaysFirstEvenInImpossibleCombinedEnv() {
        // SYNTHETIC DEFENSIVE fixture: an env carrying both tmux vars and
        // TERM_PROGRAM=ghostty is unreachable in reality (tmux panes set
        // TERM_PROGRAM=tmux). The assertion pins that tmux stays first in the registry
        // if the impossible ever happens.
        let env = ["TMUX": "/s,1,0", "TMUX_PANE": "%3", "TERM_PROGRAM": "ghostty",
                   "PWD": "/p"]
        XCTAssertTrue(RevealerRegistry.detect(env) is TmuxRevealer)
    }

    // MARK: userInfo handoff

    func testRevealUserInfoWithCwd() {
        let r = GhosttyRevealer(cwd: "/proj")
        XCTAssertEqual(r.revealUserInfo, ["terminal": "ghostty", "cwd": "/proj"])
    }

    func testRevealUserInfoWithoutCwd() {
        let r = GhosttyRevealer(cwd: nil)
        XCTAssertEqual(r.revealUserInfo, ["terminal": "ghostty"])
    }

    func testRevealFromRoundTripsViaRegistry() {
        let rebuilt = RevealerRegistry.revealer(from: ["terminal": "ghostty", "cwd": "/proj"])
        let ghostty = rebuilt as? GhosttyRevealer
        XCTAssertEqual(ghostty?.cwd, "/proj")
        XCTAssertEqual(ghostty?.capability, .precise)
    }

    func testRevealFromWithoutCwdIsAppOnly() {
        // The dict is self-sufficient for the relaunch responder (no env at all): a
        // tag-only dict reconstructs an app-only revealer, not nil.
        let rebuilt = RevealerRegistry.revealer(from: ["terminal": "ghostty"])
        let ghostty = rebuilt as? GhosttyRevealer
        XCTAssertNotNil(ghostty)
        XCTAssertNil(ghostty?.cwd)
        XCTAssertEqual(ghostty?.capability, .appOnly)
    }

    func testRevealFromEmptyCwdIsAppOnly() {
        let ghostty = GhosttyRevealer.reveal(from: ["terminal": "ghostty", "cwd": ""])
            as? GhosttyRevealer
        XCTAssertNotNil(ghostty)
        XCTAssertNil(ghostty?.cwd)
    }

    func testRevealFromRejectsWrongTagAndEmptyDict() {
        XCTAssertNil(GhosttyRevealer.reveal(from: ["terminal": "iterm2", "session": "G"]))
        XCTAssertNil(GhosttyRevealer.reveal(from: ["terminal": "tmux", "socket": "/s",
                                                   "pane": "%3"]))
        XCTAssertNil(GhosttyRevealer.reveal(from: [:]))
    }
}
