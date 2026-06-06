import XCTest
@testable import pesterm

final class ClaudePermissionAdapterTests: XCTestCase {

    // MARK: parse

    func testParseValidBashPayload() {
        let json = #"""
        {"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"},"cwd":"/x/proj","session_id":"abcdef123456"}
        """#
        let p = ClaudePermissionAdapter.parse(Data(json.utf8))
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.toolName, "Bash")
        XCTAssertEqual(p?.cwd, "/x/proj")
        XCTAssertEqual(p?.sessionId, "abcdef123456")
    }

    func testParseEmptyReturnsNil() {
        XCTAssertNil(ClaudePermissionAdapter.parse(Data()))
    }

    func testParseInvalidReturnsNil() {
        XCTAssertNil(ClaudePermissionAdapter.parse(Data("not json".utf8)))
    }

    // MARK: approvableText

    func testApprovableTextBashFullCommand() {
        let json = #"{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}"#
        let p = ClaudePermissionAdapter.parse(Data(json.utf8))!
        XCTAssertEqual(ClaudePermissionAdapter.approvableText(from: p),
                       "git push --force origin main")
    }

    func testApprovableTextWriteShowsFilePath() {
        let json = #"{"tool_name":"Write","tool_input":{"file_path":"/x/proj/secrets.env","content":"…"}}"#
        let p = ClaudePermissionAdapter.parse(Data(json.utf8))!
        XCTAssertEqual(ClaudePermissionAdapter.approvableText(from: p),
                       "Write /x/proj/secrets.env")
    }

    func testApprovableTextWebFetchShowsUrl() {
        let json = #"{"tool_name":"WebFetch","tool_input":{"url":"https://evil.example/x","prompt":"summarize"}}"#
        let p = ClaudePermissionAdapter.parse(Data(json.utf8))!
        XCTAssertEqual(ClaudePermissionAdapter.approvableText(from: p),
                       "WebFetch https://evil.example/x")
    }

    // Non-Bash with no known target key falls back to a truthful key=value summary —
    // NEVER a target-hiding generic like "<tool> permission".
    func testApprovableTextUnknownToolTruthfulSummary() {
        let json = #"{"tool_name":"CustomTool","tool_input":{"target":"/etc/hosts","mode":"w"}}"#
        let p = ClaudePermissionAdapter.parse(Data(json.utf8))!
        let text = ClaudePermissionAdapter.approvableText(from: p)
        XCTAssertFalse(text.contains("permission"), "must not be a target-hiding generic")
        XCTAssertTrue(text.contains("/etc/hosts"), "must show the real target")
        XCTAssertTrue(text.hasPrefix("CustomTool"))
    }

    func testApprovableTextNeverGenericForKnownTool() {
        // Even with no renderable input, we name the tool truthfully (no fake target).
        let json = #"{"tool_name":"Bash","tool_input":{}}"#
        let p = ClaudePermissionAdapter.parse(Data(json.utf8))!
        let text = ClaudePermissionAdapter.approvableText(from: p)
        XCTAssertFalse(text.contains("permission"))
        XCTAssertEqual(text, "Bash")
    }

    // MARK: shortSessionId

    func testShortSessionId() {
        XCTAssertEqual(ClaudePermissionAdapter.shortSessionId("abcdef123456"), "abcdef")
        XCTAssertEqual(ClaudePermissionAdapter.shortSessionId("ab"), "ab")
        XCTAssertEqual(ClaudePermissionAdapter.shortSessionId(""), "?")
        XCTAssertEqual(ClaudePermissionAdapter.shortSessionId(nil), "?")
    }

    // MARK: title / subtitle distinguishability

    func testBannerTitleIncludesTool() {
        let title = ClaudePermissionAdapter.bannerTitle(toolName: "Bash", sessionId: "abc123")
        XCTAssertTrue(title.contains("Bash"))
    }

    func testBannerSubtitleIncludesProjectAndShortSession() {
        let sub = ClaudePermissionAdapter.bannerSubtitle(toolName: "Bash", cwd: "/x/proj",
                                                         sessionId: "abcdef123456")
        XCTAssertTrue(sub.contains("proj"))
        XCTAssertTrue(sub.contains("abcdef"))
    }

    // MARK: group prefix

    func testGroupPrefixIsDistinctFromInfo() {
        XCTAssertEqual(ClaudePermissionAdapter.groupPrefix, "claude-perm-")
        XCTAssertNotEqual(ClaudePermissionAdapter.groupPrefix, ClaudeAdapter.groupPrefix)
    }

    func testBuildRequestGroupIsPermPrefixed() {
        let json = #"{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/x/proj","session_id":"s"}"#
        let p = ClaudePermissionAdapter.parse(Data(json.utf8))!
        let req = ClaudePermissionAdapter.buildRequest(from: p, iTermSessionId: "GUID123")
        XCTAssertEqual(req?.groupID, "claude-perm-GUID123")
        XCTAssertNotEqual(req?.groupID, "claude-GUID123")
    }

    // MARK: buildRequest is a .permission request

    func testBuildRequestIsPermissionKind() {
        let json = #"{"tool_name":"Bash","tool_input":{"command":"ls -la"},"cwd":"/x/proj","session_id":"abcdef"}"#
        let p = ClaudePermissionAdapter.parse(Data(json.utf8))!
        let req = ClaudePermissionAdapter.buildRequest(from: p, iTermSessionId: "G")!
        XCTAssertEqual(req.kind, .permission)
        XCTAssertEqual(req.body, "ls -la")
        XCTAssertEqual(req.sound, "Hero")
        XCTAssertEqual(req.source, .claude)
        XCTAssertTrue(req.title.contains("Bash"))
        XCTAssertTrue(req.subtitle?.contains("proj") ?? false)
    }

    func testBuildRequestNilSessionNoGroup() {
        let json = #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#
        let p = ClaudePermissionAdapter.parse(Data(json.utf8))!
        let req = ClaudePermissionAdapter.buildRequest(from: p, iTermSessionId: nil)
        XCTAssertNil(req?.groupID)
    }
}
