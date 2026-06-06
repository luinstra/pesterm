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

    // INFO content leaves categoryIdentifier empty (no action buttons; whole body is
    // the click target → reveal). This guards the unchanged info path.
    func testInfoContentHasEmptyCategory() {
        let req = NotificationRequest(title: "t", body: "b", kind: .info)
        let c = UNUserNotificationBackend.makeContent(from: req)
        XCTAssertEqual(c.categoryIdentifier, "")
    }

    // PERMISSION content sets the pesterm.permission category so Approve/Deny render.
    func testPermissionContentHasPermissionCategory() {
        let req = NotificationRequest(title: "t", body: "b", kind: .permission)
        let c = UNUserNotificationBackend.makeContent(from: req)
        XCTAssertEqual(c.categoryIdentifier, "pesterm.permission")
    }

    // The permission category carries exactly [Approve, Deny] in that order.
    func testPermissionCategoryActions() {
        let cat = UNUserNotificationBackend.permissionCategory()
        XCTAssertEqual(cat.identifier, "pesterm.permission")
        XCTAssertEqual(cat.actions.count, 2)
        XCTAssertEqual(cat.actions[0].identifier, "pesterm.approve")
        XCTAssertEqual(cat.actions[0].title, "Approve")
        XCTAssertEqual(cat.actions[1].identifier, "pesterm.deny")
        XCTAssertEqual(cat.actions[1].title, "Deny")
    }
}
