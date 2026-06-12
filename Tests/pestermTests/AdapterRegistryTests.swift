import XCTest
@testable import pesterm

/// Covers the agent-axis dispatch: registry lookup (replacing the old AdapterDispatch
/// routing tests) and the per-adapter `outcome` mapping (post vs. suppress).
final class AdapterRegistryTests: XCTestCase {

    // MARK: lookup (migrated from AdapterDispatch routing)

    func testClaudeResolvesToInfoAdapter() {
        let a = AdapterRegistry.adapter(for: "claude")
        XCTAssertEqual(a?.adapterValue, "claude")
        XCTAssertEqual(a?.kind, .info)
    }

    func testClaudePermissionResolvesToPermissionAdapter() {
        let a = AdapterRegistry.adapter(for: "claude-permission")
        XCTAssertEqual(a?.adapterValue, "claude-permission")
        XCTAssertEqual(a?.kind, .permission)
    }

    func testUnknownAdapterIsNil() {
        XCTAssertNil(AdapterRegistry.adapter(for: "codex"))
        XCTAssertNil(AdapterRegistry.adapter(for: ""))
        XCTAssertNil(AdapterRegistry.adapter(for: "claude-x"))
    }

    // MARK: group prefix derived from a single source-of-truth

    func testGroupPrefixDerivedFromSource() {
        XCTAssertEqual(AgentSource.claude.groupPrefix(for: .info), "claude-")
        XCTAssertEqual(AgentSource.claude.groupPrefix(for: .permission), "claude-perm-")
        XCTAssertEqual(AgentSource.generic.groupPrefix(for: .info), "pesterm-")
    }

    // MARK: outcome — info adapter

    func testInfoEmptyStdinSuppresses() {
        guard case .suppress = ClaudeAdapter.outcome(stdin: Data(), iTermSessionId: nil,
                                                     soundOverride: nil) else {
            return XCTFail("empty stdin should suppress")
        }
    }

    func testInfoValidPayloadPosts() {
        let json = #"{"notification_type":"idle_prompt","cwd":"/x/proj"}"#
        guard case .post(let req) = ClaudeAdapter.outcome(stdin: Data(json.utf8),
                                                          iTermSessionId: "G",
                                                          soundOverride: nil) else {
            return XCTFail("valid idle_prompt should post")
        }
        XCTAssertEqual(req.kind, .info)
        XCTAssertEqual(req.groupID, "claude-G")
    }

    func testInfoAuthSuccessSuppressesWithReason() {
        let json = #"{"notification_type":"auth_success"}"#
        guard case .suppress(let msg) = ClaudeAdapter.outcome(stdin: Data(json.utf8),
                                                              iTermSessionId: nil,
                                                              soundOverride: nil) else {
            return XCTFail("auth_success should suppress")
        }
        XCTAssertTrue(msg.contains("auth_success"))
    }

    func testInfoSoundOverrideApplies() {
        let json = #"{"notification_type":"idle_prompt"}"#
        guard case .post(let req) = ClaudeAdapter.outcome(stdin: Data(json.utf8),
                                                          iTermSessionId: nil,
                                                          soundOverride: "Glass") else {
            return XCTFail("idle_prompt should post")
        }
        XCTAssertEqual(req.sound, "Glass")
    }

    // MARK: outcome — permission adapter

    func testPermissionEmptyStdinSuppresses() {
        guard case .suppress = ClaudePermissionAdapter.outcome(stdin: Data(), iTermSessionId: nil,
                                                               soundOverride: nil) else {
            return XCTFail("empty stdin should suppress")
        }
    }

    func testPermissionUnmediatedToolSuppresses() {
        let json = #"{"tool_name":"AskUserQuestion","tool_input":{}}"#
        guard case .suppress(let msg) = ClaudePermissionAdapter.outcome(stdin: Data(json.utf8),
                                                                        iTermSessionId: nil,
                                                                        soundOverride: nil) else {
            return XCTFail("AskUserQuestion should suppress to terminal fallback")
        }
        XCTAssertTrue(msg.contains("not mediated"))
    }

    func testPermissionMediatedToolPosts() {
        let json = #"{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"s"}"#
        guard case .post(let req) = ClaudePermissionAdapter.outcome(stdin: Data(json.utf8),
                                                                    iTermSessionId: "G",
                                                                    soundOverride: nil) else {
            return XCTFail("Bash should post a permission request")
        }
        XCTAssertEqual(req.kind, .permission)
        XCTAssertEqual(req.groupID, "claude-perm-G")
    }

    func testPermissionIgnoresSoundOverride() {
        // --sound applies to the info path only; permission sound is fixed.
        let json = #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#
        guard case .post(let req) = ClaudePermissionAdapter.outcome(stdin: Data(json.utf8),
                                                                    iTermSessionId: nil,
                                                                    soundOverride: "Glass") else {
            return XCTFail("Bash should post")
        }
        XCTAssertEqual(req.sound, "Hero")
    }
}
