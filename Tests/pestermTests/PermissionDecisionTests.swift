import XCTest
@testable import pesterm

final class PermissionDecisionTests: XCTestCase {

    func testAllowExactBytes() {
        XCTAssertEqual(
            PermissionDecision.outputJSON(for: .allow),
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
    }

    func testDenyExactBytes() {
        XCTAssertEqual(
            PermissionDecision.outputJSON(for: .deny),
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#)
    }

    func testTimeoutEmitsNothing() {
        XCTAssertNil(PermissionDecision.outputJSON(for: .timeout))
    }

    // The contract is locked: hookEventName is PermissionRequest, only allow/deny
    // behaviors, no updatedInput, no always.
    func testNoForbiddenKeys() {
        for d in [PermissionDecision.allow, .deny] {
            let json = PermissionDecision.outputJSON(for: d)!
            XCTAssertTrue(json.contains(#""hookEventName":"PermissionRequest""#))
            XCTAssertFalse(json.contains("updatedInput"))
            XCTAssertFalse(json.contains("always"))
        }
    }
}
