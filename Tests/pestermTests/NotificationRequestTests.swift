import XCTest
@testable import pesterm

final class NotificationRequestTests: XCTestCase {

    // kind defaults to .info so every existing call site is unchanged.
    func testKindDefaultsToInfo() {
        let req = NotificationRequest(title: "t", body: "b")
        XCTAssertEqual(req.kind, .info)
    }

    func testKindCanBePermission() {
        let req = NotificationRequest(title: "t", body: "b", kind: .permission)
        XCTAssertEqual(req.kind, .permission)
    }

    // The hand-written init still threads every existing field through unchanged.
    func testInitThreadsAllFields() {
        let req = NotificationRequest(title: "T", subtitle: "S", body: "B", sound: "Hero",
                                      source: .claude, groupID: "g", kind: .permission)
        XCTAssertEqual(req.title, "T")
        XCTAssertEqual(req.subtitle, "S")
        XCTAssertEqual(req.body, "B")
        XCTAssertEqual(req.sound, "Hero")
        XCTAssertEqual(req.source, .claude)
        XCTAssertEqual(req.groupID, "g")
        XCTAssertEqual(req.kind, .permission)
    }
}
