import XCTest
@testable import pesterm

/// The pure dismissal-detection decision: exit only when our notification is ABSENT from
/// the delivered list AFTER having been seen there (so the async-delivery startup race
/// never triggers a spurious immediate exit).
final class DismissDecisionTests: XCTestCase {

    func testPresentLatchesSeenAndDoesNotExit() {
        let r = UNUserNotificationBackend.dismissDecision(present: true, sawDelivered: false)
        XCTAssertTrue(r.sawDelivered)
        XCTAssertFalse(r.exit)
    }

    func testAbsentBeforeEverSeenDoesNotExit() {
        // Startup race: not delivered yet. Must NOT exit (and must not latch seen).
        let r = UNUserNotificationBackend.dismissDecision(present: false, sawDelivered: false)
        XCTAssertFalse(r.sawDelivered)
        XCTAssertFalse(r.exit)
    }

    func testAbsentAfterSeenExits() {
        // Seen, now gone → dismissed/cleared/expired → exit.
        let r = UNUserNotificationBackend.dismissDecision(present: false, sawDelivered: true)
        XCTAssertTrue(r.exit)
    }

    func testStillPresentAfterSeenStaysAlive() {
        let r = UNUserNotificationBackend.dismissDecision(present: true, sawDelivered: true)
        XCTAssertTrue(r.sawDelivered)
        XCTAssertFalse(r.exit)
    }
}
