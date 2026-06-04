import XCTest
@testable import pesterm

final class AgentSourceTests: XCTestCase {

    func testParsesClaude() {
        XCTAssertEqual(AgentSource(argument: "claude"), .claude)
    }

    func testParsesGeneric() {
        XCTAssertEqual(AgentSource(argument: "generic"), .generic)
    }

    func testUnknownReturnsNil() {
        XCTAssertNil(AgentSource(argument: "codex"))
    }

    func testDefaultIsGeneric() {
        XCTAssertEqual(AgentSource.default, .generic)
    }
}
