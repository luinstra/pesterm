import XCTest
import AppKit
@testable import pesterm

final class NSUserNotificationBackendTests: XCTestCase {

    // The banner must carry NO action button. macOS adds a default "Show" button when
    // hasActionButton is true (its default); we kill it so the whole body is the only
    // click affordance. This guards against the default creeping back in a refactor.
    func testNoActionButton() {
        let req = NotificationRequest(title: "Claude Code", body: "Permission required")
        let n = NSUserNotificationBackend.makeNotification(from: req)
        XCTAssertFalse(n.hasActionButton, "no default 'Show' button — body click reveals")
    }

    // The pure builder maps the request fields straight through.
    func testMapsRequestFields() {
        let req = NotificationRequest(title: "Claude Code", subtitle: "proj",
                                      body: "Awaiting your input", sound: "Morse",
                                      source: .claude, groupID: "claude-GUID")
        let n = NSUserNotificationBackend.makeNotification(from: req)
        XCTAssertEqual(n.title, "Claude Code")
        XCTAssertEqual(n.subtitle, "proj")
        XCTAssertEqual(n.informativeText, "Awaiting your input")
        XCTAssertEqual(n.soundName, "Morse")
        // --group → identifier (the coalescing key).
        XCTAssertEqual(n.identifier, "claude-GUID")
    }

    // No sound / no group → those fields stay unset (no empty-string identifier, etc.).
    func testOptionalFieldsUnset() {
        let req = NotificationRequest(title: "t", body: "b")
        let n = NSUserNotificationBackend.makeNotification(from: req)
        XCTAssertNil(n.soundName)
        XCTAssertNil(n.identifier)
        XCTAssertFalse(n.hasActionButton)
    }
}
