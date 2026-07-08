import XCTest
@testable import pesterm

/// Pure core of the Ghostty revealer: env capture, cwd normalization, the
/// one-match-or-fallback terminal choice, and the grant-aware miss diagnostics.
/// The ScriptingBridge traversal (`CGhosttyBridge`) is the impure shell — exercised by
/// manual acceptance checks on a live Ghostty, never here.
final class GhosttyEnvTests: XCTestCase {

    // MARK: captureTarget — the single gate feeding detection AND CoalescingKey

    func testCaptureTargetHappy() {
        let t = GhosttyEnv.captureTarget(env: ["TERM_PROGRAM": "ghostty", "PWD": "/proj"])
        XCTAssertNotNil(t)
        XCTAssertEqual(t?.cwd, "/proj")
    }

    func testCaptureTargetIsCaseSensitiveExactMatch() {
        // Ghostty sets TERM_PROGRAM=ghostty (lowercase — its own docs test exactly that);
        // any other casing is NOT Ghostty.
        XCTAssertNil(GhosttyEnv.captureTarget(env: ["TERM_PROGRAM": "Ghostty", "PWD": "/p"]))
        XCTAssertNil(GhosttyEnv.captureTarget(env: ["TERM_PROGRAM": "GHOSTTY", "PWD": "/p"]))
    }

    func testCaptureTargetNilForOtherTerminals() {
        XCTAssertNil(GhosttyEnv.captureTarget(env: ["TERM_PROGRAM": "iTerm.app", "PWD": "/p"]))
        XCTAssertNil(GhosttyEnv.captureTarget(env: ["TERM_PROGRAM": "tmux", "PWD": "/p"]))
        XCTAssertNil(GhosttyEnv.captureTarget(env: ["PWD": "/p"]))
        XCTAssertNil(GhosttyEnv.captureTarget(env: [:]))
    }

    func testCaptureTargetDetectsWithoutPWD() {
        // No PWD → still Ghostty (app-only tier), with a nil cwd — detection must not
        // collapse just because the precise key is missing.
        let noPwd = GhosttyEnv.captureTarget(env: ["TERM_PROGRAM": "ghostty"])
        XCTAssertNotNil(noPwd)
        XCTAssertNil(noPwd?.cwd)

        let emptyPwd = GhosttyEnv.captureTarget(env: ["TERM_PROGRAM": "ghostty", "PWD": ""])
        XCTAssertNotNil(emptyPwd)
        XCTAssertNil(emptyPwd?.cwd)
    }

    func testCaptureTargetTreatsWhitespaceOnlyPWDAsAbsent() {
        // A "   " PWD would otherwise pass a naive non-empty check, normalize to "",
        // and could then MATCH a terminal reporting an empty working directory —
        // a wrong-tab risk. Whitespace-only → app-only capture, same as absent.
        let t = GhosttyEnv.captureTarget(env: ["TERM_PROGRAM": "ghostty", "PWD": "   \n"])
        XCTAssertNotNil(t)
        XCTAssertNil(t?.cwd)
    }

    // MARK: normalizePath

    func testNormalizePathStripsSingleTrailingSlash() {
        XCTAssertEqual(GhosttyEnv.normalizePath("/proj/"), "/proj")
        XCTAssertEqual(GhosttyEnv.normalizePath("/proj"), "/proj", "idempotent")
        // Only a SINGLE trailing slash is stripped (defensive, not a full canonicalizer).
        XCTAssertEqual(GhosttyEnv.normalizePath("/proj//"), "/proj/")
    }

    func testNormalizePathKeepsRoot() {
        XCTAssertEqual(GhosttyEnv.normalizePath("/"), "/")
    }

    func testNormalizePathTrimsWhitespace() {
        XCTAssertEqual(GhosttyEnv.normalizePath("  /proj\n"), "/proj")
        XCTAssertEqual(GhosttyEnv.normalizePath("/proj \n"), "/proj")
    }

    // MARK: chooseTerminal — one → reveal it; zero/many → fall back; never guess

    private func candidate(_ n: Int, cwd: String) -> GhosttyEnv.Candidate {
        GhosttyEnv.Candidate(
            identity: GhosttyEnv.TerminalIdentity(windowId: "w\(n)", tabId: "t\(n)",
                                                  terminalId: "s\(n)"),
            cwd: cwd)
    }

    func testChooseTerminalExactlyOne() {
        let c = [candidate(1, cwd: "/a"), candidate(2, cwd: "/b")]
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "/b", candidates: c),
                       .one(GhosttyEnv.TerminalIdentity(windowId: "w2", tabId: "t2",
                                                        terminalId: "s2")))
    }

    func testChooseTerminalNoMatch() {
        let c = [candidate(1, cwd: "/a")]
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "/z", candidates: c), .noMatch)
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "/z", candidates: []), .noMatch)
    }

    func testChooseTerminalMultipleCarriesCount() {
        let c = [candidate(1, cwd: "/a"), candidate(2, cwd: "/a"), candidate(3, cwd: "/a")]
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "/a", candidates: c),
                       .multiple(count: 3))
    }

    func testChooseTerminalNearMissPathsDoNotMatch() {
        // Exact compare after normalization — /a/b must never match /a/bc (no prefix
        // matching, no substring matching).
        let c = [candidate(1, cwd: "/a/bc")]
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "/a/b", candidates: c), .noMatch)
    }

    func testChooseTerminalTrailingSlashEquivalence() {
        let c = [candidate(1, cwd: "/proj/")]
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "/proj", candidates: c),
                       .one(c[0].identity))
    }

    func testChooseTerminalEmptyCandidateCwdNeverMatches() {
        // The bridge maps an absent working directory to "" — that must never match a
        // real captured PWD.
        let c = [candidate(1, cwd: "")]
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "/proj", candidates: c), .noMatch)
    }

    func testChooseTerminalEmptyMatchCwdIsNeverOne() {
        // Belt-and-braces behind the captureTarget whitespace gate: even if an
        // empty/whitespace cwd reached the matcher, it must return .noMatch — never
        // .one against a terminal that also reports an empty working directory.
        let c = [candidate(1, cwd: ""), candidate(2, cwd: "/proj")]
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "", candidates: c), .noMatch)
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "   \n", candidates: c), .noMatch)
    }

    func testChooseTerminalSymlinkResolvedRetry() {
        // Live check 1 VERDICT (2026-07-02, Ghostty 1.3.1 — docs/ghostty-sdef-findings.md):
        // GO. Ghostty reports the LOGICAL path (`/tmp` for `/tmp`), byte-equal to $PWD, so
        // the raw compare is the hot path and this retry branch is belt-and-braces for
        // exotic setups. The /tmp ↔ /private/tmp fixture below is kept deliberately: it
        // pins that the retry still reconciles a logical/physical mismatch if a future
        // Ghostty (or unusual filesystem) ever produces one.
        let physical = [candidate(1, cwd: "/private/tmp")]
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "/tmp", candidates: physical),
                       .one(physical[0].identity))

        let logical = [candidate(1, cwd: "/tmp")]
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "/private/tmp", candidates: logical),
                       .one(logical[0].identity))
    }

    func testChooseTerminalRawMatchWinsBeforeSymlinkRetry() {
        // The raw-compare branch runs first: an exact raw match must be found without
        // the resolved retry ever being consulted (which could otherwise merge two
        // distinct-looking candidates).
        let c = [candidate(1, cwd: "/tmp"), candidate(2, cwd: "/private/tmp")]
        XCTAssertEqual(GhosttyEnv.chooseTerminal(matching: "/tmp", candidates: c),
                       .one(c[0].identity))
    }

    // MARK: missDiagnostic — blame the grant only when the grant is the problem

    func testMissDiagnosticNoMatchWithGrantNamesCwdAndCauses() {
        let s = GhosttyEnv.missDiagnostic(choice: .noMatch, cwd: "/proj", grant: .granted)
        XCTAssertTrue(s.contains("/proj"))
        XCTAssertTrue(s.contains("macos-applescript"),
                      "with the grant fine, the other silent causes must be named")
        XCTAssertFalse(s.contains("Automation"),
                       "grant is fine — don't send the user to System Settings")
        XCTAssertTrue(s.hasSuffix("revealed app only"))
    }

    func testMissDiagnosticNoMatchWithoutGrantBlamesTheGrant() {
        // An ungranted traversal sees ZERO windows — the same silent-failure trap the
        // tmux path already hit. The message must name the Automation grant.
        for grant in [AutomationGrant.State.denied, .needsPrompt] {
            let s = GhosttyEnv.missDiagnostic(choice: .noMatch, cwd: "/proj", grant: grant)
            XCTAssertTrue(s.contains("Automation") || s.contains("automation"),
                          "missing grant must be named for \(grant)")
            XCTAssertTrue(s.hasSuffix("revealed app only"))
        }
    }

    func testMissDiagnosticMultipleStatesTheCount() {
        let s = GhosttyEnv.missDiagnostic(choice: .multiple(count: 2), cwd: "/proj",
                                          grant: .granted)
        XCTAssertTrue(s.contains("2"))
        XCTAssertTrue(s.contains("/proj"))
        XCTAssertTrue(s.hasSuffix("revealed app only"))
    }

    // MARK: focusedCwdMatches (focus probe) — mirrors chooseTerminal's two-pass compare

    func testFocusedCwdMatchesExact() {
        XCTAssertTrue(GhosttyEnv.focusedCwdMatches(captured: "/Users/me/proj",
                                                   focused: "/Users/me/proj"))
    }

    func testFocusedCwdMatchesTrailingSlash() {
        XCTAssertTrue(GhosttyEnv.focusedCwdMatches(captured: "/Users/me/proj/",
                                                   focused: "/Users/me/proj"))
        XCTAssertTrue(GhosttyEnv.focusedCwdMatches(captured: "/Users/me/proj",
                                                   focused: "/Users/me/proj/"))
    }

    func testFocusedCwdMatchesSymlinkResolvedRetry() {
        // $PWD is the shell's LOGICAL path; `working directory` may be physical.
        XCTAssertTrue(GhosttyEnv.focusedCwdMatches(captured: "/tmp",
                                                   focused: "/private/tmp"))
        XCTAssertTrue(GhosttyEnv.focusedCwdMatches(captured: "/private/tmp",
                                                   focused: "/tmp"))
    }

    func testFocusedCwdMatchesRejectsNilEmptyWhitespaceFocused() {
        XCTAssertFalse(GhosttyEnv.focusedCwdMatches(captured: "/Users/me/proj", focused: nil))
        XCTAssertFalse(GhosttyEnv.focusedCwdMatches(captured: "/Users/me/proj", focused: ""))
        XCTAssertFalse(GhosttyEnv.focusedCwdMatches(captured: "/Users/me/proj", focused: "  \n"))
    }

    func testFocusedCwdMatchesRejectsEmptyCaptured() {
        // The empty-match guard: an absent match key must never pair with a terminal
        // reporting an empty working directory.
        XCTAssertFalse(GhosttyEnv.focusedCwdMatches(captured: "", focused: ""))
        XCTAssertFalse(GhosttyEnv.focusedCwdMatches(captured: "  ", focused: "/x"))
    }

    func testFocusedCwdMatchesMismatch() {
        XCTAssertFalse(GhosttyEnv.focusedCwdMatches(captured: "/Users/me/proj",
                                                    focused: "/Users/me/other"))
    }
}
