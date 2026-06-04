import XCTest
@testable import pesterm

final class ClaudeAdapterTests: XCTestCase {

    // eventMapping — EXACT prototype parity.

    func testIdlePromptMapping() {
        let m = ClaudeAdapter.eventMapping(notificationType: "idle_prompt")
        XCTAssertEqual(m?.message, "Awaiting your input")
        XCTAssertEqual(m?.sound, "Morse")
    }

    func testPermissionPromptMapping() {
        let m = ClaudeAdapter.eventMapping(notificationType: "permission_prompt")
        XCTAssertEqual(m?.message, "Permission required")
        XCTAssertEqual(m?.sound, "Hero")
    }

    func testElicitationDialogMapping() {
        let m = ClaudeAdapter.eventMapping(notificationType: "elicitation_dialog")
        XCTAssertEqual(m?.message, "Question for you")
        XCTAssertEqual(m?.sound, "Pop")
    }

    func testAuthSuccessSuppressed() {
        XCTAssertNil(ClaudeAdapter.eventMapping(notificationType: "auth_success"))
    }

    func testUnknownSuppressed() {
        XCTAssertNil(ClaudeAdapter.eventMapping(notificationType: "something_else"))
    }

    func testMissingTypeSuppressed() {
        XCTAssertNil(ClaudeAdapter.eventMapping(notificationType: nil))
    }

    // JSON parsing.

    func testParseValidPayload() {
        let json = #"{"notification_type":"permission_prompt","message":"Allow?","cwd":"/x/proj","session_id":"abc"}"#
        let payload = ClaudeAdapter.parse(Data(json.utf8))
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.notificationType, "permission_prompt")
        XCTAssertEqual(payload?.message, "Allow?")
        XCTAssertEqual(payload?.cwd, "/x/proj")
        XCTAssertEqual(payload?.sessionId, "abc")
    }

    func testParseEmptyDataReturnsNil() {
        XCTAssertNil(ClaudeAdapter.parse(Data()))
    }

    func testParseInvalidJSONReturnsNil() {
        XCTAssertNil(ClaudeAdapter.parse(Data("not json".utf8)))
    }

    func testParseToleratesMissingOptionalFields() {
        let json = #"{"notification_type":"idle_prompt"}"#
        let payload = ClaudeAdapter.parse(Data(json.utf8))
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.notificationType, "idle_prompt")
        XCTAssertNil(payload?.message)
        XCTAssertNil(payload?.cwd)
    }

    // projectSubtitle — basename of cwd (${PWD##*/}).

    func testProjectSubtitleBasename() {
        XCTAssertEqual(ClaudeAdapter.projectSubtitle(cwd: "/Users/me/work/proj"), "proj")
    }

    func testProjectSubtitleTrailingSlash() {
        XCTAssertEqual(ClaudeAdapter.projectSubtitle(cwd: "/Users/me/work/proj/"), "proj")
    }

    func testProjectSubtitleNilFallsBackToCwd() {
        // Falls back to the process working dir; just assert it's non-empty.
        XCTAssertFalse(ClaudeAdapter.projectSubtitle(cwd: nil).isEmpty)
    }

    // buildRequest — end-to-end of the pure layer.

    func testBuildRequestPermissionPrompt() {
        let payload = ClaudeAdapter.parse(
            Data(#"{"notification_type":"permission_prompt","cwd":"/x/proj"}"#.utf8))!
        let req = ClaudeAdapter.buildRequest(from: payload, iTermSessionId: "GUID123")
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.title, "Claude Code")
        XCTAssertEqual(req?.subtitle, "proj")
        XCTAssertEqual(req?.body, "Permission required")
        XCTAssertEqual(req?.sound, "Hero")
        XCTAssertEqual(req?.source, .claude)
        XCTAssertEqual(req?.groupID, "claude-GUID123")
    }

    func testBuildRequestSuppressedReturnsNil() {
        let payload = ClaudeAdapter.parse(
            Data(#"{"notification_type":"auth_success"}"#.utf8))!
        XCTAssertNil(ClaudeAdapter.buildRequest(from: payload, iTermSessionId: "GUID"))
    }

    func testBuildRequestNilSessionIdNoGroup() {
        let payload = ClaudeAdapter.parse(
            Data(#"{"notification_type":"idle_prompt","cwd":"/a/b"}"#.utf8))!
        let req = ClaudeAdapter.buildRequest(from: payload, iTermSessionId: nil)
        XCTAssertNil(req?.groupID)
        XCTAssertEqual(req?.body, "Awaiting your input")
        XCTAssertEqual(req?.sound, "Morse")
    }
}
