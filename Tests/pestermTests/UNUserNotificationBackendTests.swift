import XCTest
import UserNotifications
@testable import pesterm

final class UNUserNotificationBackendTests: XCTestCase {

    // The pure builder maps the request fields straight through to the content.
    func testMapsRequestFields() {
        let req = NotificationRequest(title: "Claude Code", subtitle: "proj",
                                      body: "Awaiting your input", sound: "Morse",
                                      source: .claude, groupID: "claude-GUID")
        let c = UNUserNotificationBackend.makeContent(from: req)
        XCTAssertEqual(c.title, "Claude Code")
        XCTAssertEqual(c.subtitle, "proj")
        XCTAssertEqual(c.body, "Awaiting your input")
        XCTAssertEqual(c.sound, UNNotificationSound(named: UNNotificationSoundName("Morse")))
    }

    // No sound → content.sound stays nil (no implicit default sound).
    func testNoSoundLeavesSoundNil() {
        let req = NotificationRequest(title: "t", body: "b")
        let c = UNUserNotificationBackend.makeContent(from: req)
        XCTAssertNil(c.sound)
    }

    // Absent subtitle → empty (not the string "nil").
    func testNoSubtitleStaysEmpty() {
        let req = NotificationRequest(title: "t", body: "b")
        let c = UNUserNotificationBackend.makeContent(from: req)
        XCTAssertEqual(c.subtitle, "")
    }
}
