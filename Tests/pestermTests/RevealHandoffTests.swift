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
        // "kitty" is genuinely unregistered. (This fixture used to say "ghostty" — now
        // that GhosttyRevealer is registered, that dict reconstructs an app-only
        // revealer instead of nil; see testGhosttyTagWithoutCwdIsAppOnly.)
        XCTAssertNil(RevealerRegistry.revealer(from: ["terminal": "kitty", "session": "x"]))
    }

    func testGhosttyRevealUserInfoRoundTrips() {
        let r = GhosttyRevealer(cwd: "/proj")
        let info = r.revealUserInfo
        XCTAssertEqual(info["terminal"], "ghostty")
        XCTAssertEqual(info["cwd"], "/proj")

        let rebuilt = RevealerRegistry.revealer(from: info)
        XCTAssertEqual((rebuilt as? GhosttyRevealer)?.cwd, "/proj",
                       "a revealer reconstructed from userInfo must target the same cwd")
    }

    func testGhosttyTagWithoutCwdIsAppOnly() {
        // A tag-only ghostty dict is a valid APP-ONLY target (Ghostty has no per-surface
        // env var; the dict is self-sufficient for the relaunch responder) — non-nil,
        // unlike a truly unknown tag.
        let rebuilt = RevealerRegistry.revealer(from: ["terminal": "ghostty"])
        let ghostty = rebuilt as? GhosttyRevealer
        XCTAssertNotNil(ghostty)
        XCTAssertNil(ghostty?.cwd)
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
