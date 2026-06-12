import XCTest
import UserNotifications
@testable import pesterm

/// The reveal-target handoff: the target rides in the notification's userInfo so a click
/// delivered to any process reveals the CLICKED notification's tab (same misrouting root
/// cause as the permission decision handoff).
final class RevealHandoffTests: XCTestCase {

    func testITermRevealUserInfoRoundTrips() {
        let r = ITerm2Revealer(targetSessionId: "GUID-123")
        let info = r.revealUserInfo
        XCTAssertEqual(info["terminal"], "iterm2")
        XCTAssertEqual(info["session"], "GUID-123")

        let rebuilt = RevealerRegistry.revealer(from: info)
        XCTAssertEqual((rebuilt as? ITerm2Revealer)?.targetSessionId, "GUID-123",
                       "a revealer reconstructed from userInfo must target the same session")
    }

    func testRegistryRejectsUnknownTerminalTag() {
        XCTAssertNil(RevealerRegistry.revealer(from: ["terminal": "ghostty", "session": "x"]))
    }

    func testRegistryRejectsMissingOrEmptySession() {
        XCTAssertNil(RevealerRegistry.revealer(from: ["terminal": "iterm2"]))
        XCTAssertNil(RevealerRegistry.revealer(from: ["terminal": "iterm2", "session": ""]))
    }

    func testRevealTargetEmbeddedInNotificationUserInfo() {
        let req = NotificationRequest(title: "t", body: "b",
                                      revealUserInfo: ["terminal": "iterm2", "session": "S"])
        let content = UNUserNotificationBackend.makeContent(from: req)
        XCTAssertEqual(content.userInfo["terminal"] as? String, "iterm2")
        XCTAssertEqual(content.userInfo["session"] as? String, "S")
    }

    func testNoUserInfoWhenRevealTargetAbsent() {
        let content = UNUserNotificationBackend.makeContent(from: NotificationRequest(title: "t", body: "b"))
        XCTAssertTrue(content.userInfo.isEmpty, "no target → no userInfo (bare post stays clean)")
    }
}
