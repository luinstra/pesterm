import XCTest
@testable import pesterm

final class ITerm2RevealerTests: XCTestCase {

    // PP2: session id is the LAST component after the FINAL colon.
    func testParseSessionIdTakesLastColonComponent() {
        let raw = "w0t0p0:F7A1B2C3-1234-5678-9ABC-DEF012345678"
        XCTAssertEqual(
            ITerm2Revealer.parseSessionId(raw),
            "F7A1B2C3-1234-5678-9ABC-DEF012345678")
    }

    func testParseSessionIdWithMultipleColons() {
        let raw = "a:b:c:GUID-LAST"
        XCTAssertEqual(ITerm2Revealer.parseSessionId(raw), "GUID-LAST")
    }

    func testParseSessionIdNoColonReturnsWhole() {
        XCTAssertEqual(ITerm2Revealer.parseSessionId("plainguid"), "plainguid")
    }

    func testParseSessionIdTrailingColonReturnsEmpty() {
        // Defensive: a trailing colon means no GUID component.
        XCTAssertEqual(ITerm2Revealer.parseSessionId("w0t0p0:"), "")
    }

    // detect()

    func testDetectMatchesInsideITerm() {
        let env = [
            "TERM_PROGRAM": "iTerm.app",
            "ITERM_SESSION_ID": "w0t0p0:THE-GUID"
        ]
        let revealer = ITerm2Revealer.detect(env)
        XCTAssertNotNil(revealer)
        XCTAssertEqual((revealer as? ITerm2Revealer)?.targetSessionId, "THE-GUID")
        XCTAssertEqual(revealer?.capability, .precise)
    }

    func testDetectNilWhenNotITerm() {
        let env = [
            "TERM_PROGRAM": "Apple_Terminal",
            "ITERM_SESSION_ID": "w0t0p0:THE-GUID"
        ]
        XCTAssertNil(ITerm2Revealer.detect(env))
    }

    func testDetectNilWhenNoSessionId() {
        let env = ["TERM_PROGRAM": "iTerm.app"]
        XCTAssertNil(ITerm2Revealer.detect(env))
    }

    func testDetectNilWhenSessionIdEmpty() {
        let env = ["TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": ""]
        XCTAssertNil(ITerm2Revealer.detect(env))
    }

    func testRegistryReturnsITermInsideITerm() {
        let env = [
            "TERM_PROGRAM": "iTerm.app",
            "ITERM_SESSION_ID": "w0t0p0:REG-GUID"
        ]
        let revealer = RevealerRegistry.detect(env)
        XCTAssertTrue(revealer is ITerm2Revealer)
    }

    func testRegistryNilOutsideITerm() {
        XCTAssertNil(RevealerRegistry.detect([:]))
    }
}
