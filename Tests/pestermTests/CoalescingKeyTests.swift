import XCTest
@testable import pesterm

/// The terminal-context key that suffixes an info notification's groupID. Inside tmux,
/// ITERM_SESSION_ID is the SHARED stale GUID every pane inherited from the tmux server —
/// keying on it coalesced notifications from DIFFERENT panes into one card (pane B's ping
/// silently replaced pane A's). The key must be pane-distinct there.
final class CoalescingKeyTests: XCTestCase {

    func testTmuxKeyIsSocketAndPane() {
        let env = ["TMUX": "/s,1,0", "TMUX_PANE": "%3",
                   "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:SHAREDGUID"]
        XCTAssertEqual(CoalescingKey.fromEnv(env), "tmux:/s:%3")
    }

    func testDistinctPanesGetDistinctKeys() {
        // THE bug: two Claude sessions in different panes shared the stale GUID and
        // their info notifications replaced each other.
        let a = ["TMUX": "/s,1,0", "TMUX_PANE": "%3", "ITERM_SESSION_ID": "w0t0p0:SHAREDGUID"]
        let b = ["TMUX": "/s,1,0", "TMUX_PANE": "%7", "ITERM_SESSION_ID": "w0t0p0:SHAREDGUID"]
        XCTAssertNotEqual(CoalescingKey.fromEnv(a), CoalescingKey.fromEnv(b))
        // And neither is the shared GUID.
        XCTAssertNotEqual(CoalescingKey.fromEnv(a), "SHAREDGUID")
    }

    func testNonTmuxKeyIsITermGUID() {
        let env = ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:GUID123"]
        XCTAssertEqual(CoalescingKey.fromEnv(env), "GUID123")
    }

    func testNoTerminalContextIsNil() {
        XCTAssertNil(CoalescingKey.fromEnv([:]))
        XCTAssertNil(CoalescingKey.fromEnv(["ITERM_SESSION_ID": ""]))
    }

    func testKeySelectionMirrorsRevealerDetection() {
        // The key must go tmux exactly when the revealer does (same captureTarget gate),
        // so the coalescing identity and the reveal target never disagree.
        let tmuxEnv = ["TMUX": "/s,1,0", "TMUX_PANE": "%3",
                       "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:G"]
        XCTAssertTrue(RevealerRegistry.detect(tmuxEnv) is TmuxRevealer)
        XCTAssertTrue(CoalescingKey.fromEnv(tmuxEnv)?.hasPrefix("tmux:") == true)

        // Half-broken tmux env (no pane): revealer falls back to iTerm — so must the key.
        let halfEnv = ["TMUX": "/s,1,0",
                       "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t0p0:G"]
        XCTAssertTrue(RevealerRegistry.detect(halfEnv) is ITerm2Revealer)
        XCTAssertEqual(CoalescingKey.fromEnv(halfEnv), "G")
    }

    // MARK: ghostty branch — keyed on the same captureTarget gate as the revealer

    func testGhosttyKeyIsPrefixedPWD() {
        let env = ["TERM_PROGRAM": "ghostty", "PWD": "/proj"]
        XCTAssertEqual(CoalescingKey.fromEnv(env), "ghostty:/proj")
    }

    func testGhosttyKeyIsNormalizedLikeChooseTerminal() {
        // "/proj" vs "/proj/" must never split one session's pings into two cards.
        let env = ["TERM_PROGRAM": "ghostty", "PWD": "/proj/"]
        XCTAssertEqual(CoalescingKey.fromEnv(env), "ghostty:/proj")
    }

    func testGhosttyDistinctDirsGetDistinctKeys() {
        let a = ["TERM_PROGRAM": "ghostty", "PWD": "/proj-a"]
        let b = ["TERM_PROGRAM": "ghostty", "PWD": "/proj-b"]
        XCTAssertNotEqual(CoalescingKey.fromEnv(a), CoalescingKey.fromEnv(b))
    }

    func testGhosttyWithoutPWDIsNilNeverAShardBucket() {
        // Under-coalesce, never cross-coalesce: no PWD → post ungrouped. Any shared
        // bucket would recreate the tmux shared-stale-GUID bug (pane B silently
        // replacing pane A's card).
        XCTAssertNil(CoalescingKey.fromEnv(["TERM_PROGRAM": "ghostty"]))
        XCTAssertNil(CoalescingKey.fromEnv(["TERM_PROGRAM": "ghostty", "PWD": ""]))
        // Whitespace-only PWD is absent too — "ghostty:" (an empty-path bucket shared
        // by every such session) must never be minted.
        XCTAssertNil(CoalescingKey.fromEnv(["TERM_PROGRAM": "ghostty", "PWD": "  \n"]))
    }

    func testGhosttyBranchBeatsStrayITermSessionId() {
        // An inherited/stale ITERM_SESSION_ID inside Ghostty must never hijack the key
        // (mirrors detection mutual-exclusivity: TERM_PROGRAM gates both).
        let env = ["TERM_PROGRAM": "ghostty", "PWD": "/proj",
                   "ITERM_SESSION_ID": "w0t0p0:STRAY"]
        XCTAssertEqual(CoalescingKey.fromEnv(env), "ghostty:/proj")

        // Even app-only (no PWD) the answer is nil — NOT the stray iTerm GUID.
        let appOnly = ["TERM_PROGRAM": "ghostty", "ITERM_SESSION_ID": "w0t0p0:STRAY"]
        XCTAssertNil(CoalescingKey.fromEnv(appOnly))
    }

    func testGhosttyKeyMirrorsRevealerDetectionPrecisely() {
        // PRECISE biconditionals — the naive "detects ⇔ ghostty:-prefix" is FALSE for
        // the app-only case: Ghostty detects on TERM_PROGRAM alone, the key additionally
        // needs PWD. One gate (GhosttyEnv.captureTarget), two outputs, never disagreeing
        // on WHICH terminal.
        // (a) TERM_PROGRAM=ghostty + PWD → GhosttyRevealer AND a ghostty:-prefixed key.
        let precise = ["TERM_PROGRAM": "ghostty", "PWD": "/proj"]
        XCTAssertTrue(RevealerRegistry.detect(precise) is GhosttyRevealer)
        XCTAssertTrue(CoalescingKey.fromEnv(precise)?.hasPrefix("ghostty:") == true)

        // (b) TERM_PROGRAM=ghostty + no PWD → STILL GhosttyRevealer (app-only) AND a
        // nil key (documented app-only under-coalesce).
        let appOnly = ["TERM_PROGRAM": "ghostty"]
        let revealer = RevealerRegistry.detect(appOnly)
        XCTAssertTrue(revealer is GhosttyRevealer)
        XCTAssertEqual(revealer?.capability, .appOnly)
        XCTAssertNil(CoalescingKey.fromEnv(appOnly))

        // (c) non-ghostty env → neither.
        let other = ["TERM_PROGRAM": "Apple_Terminal", "PWD": "/proj"]
        XCTAssertFalse(RevealerRegistry.detect(other) is GhosttyRevealer)
        XCTAssertNil(CoalescingKey.fromEnv(other))
    }
}
