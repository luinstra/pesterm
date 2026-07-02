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
}
