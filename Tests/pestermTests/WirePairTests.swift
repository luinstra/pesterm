import XCTest
@testable import pesterm

/// Pair wiring (Notification + PermissionRequest) at the merger/registry layer — the
/// same load-once / fold-each / write-once sequence the CLI commands run, exercised
/// without the AppKit-exiting `run()`.
final class WirePairTests: XCTestCase {

    var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pesterm-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func path() -> String { scratch.appendingPathComponent("settings.json").path }

    private func commands(_ s: [String: Any], event: String) -> [String] {
        let entries = ((s["hooks"] as? [String: Any])?[event] as? [Any]) ?? []
        return entries.flatMap { entry -> [String] in
            guard let d = entry as? [String: Any], let hooks = d["hooks"] as? [Any] else { return [] }
            return hooks.compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    // The `matcher` key on an event's FIRST entry (nil if absent).
    private func matcher(_ s: [String: Any], event: String) -> String? {
        let entries = ((s["hooks"] as? [String: Any])?[event] as? [Any]) ?? []
        return (entries.first as? [String: Any])?["matcher"] as? String
    }

    // Exercise the PRODUCTION transform (WiringPlan.build) — the same function
    // ConfigureCommand calls — wrapped in the load/write the CLI does around it. No
    // hand-rolled copy of the loop to drift.
    @discardableResult
    private func wire(_ p: String, command: String, approvals: Bool) throws -> [String: Any] {
        let current = try SettingsMerger.load(path: p)
        let proposed = try WiringPlan.build(agent: "claude", approvals: approvals,
                                            command: command, sound: nil, current: current)
        try SettingsMerger.write(proposed, to: p)
        return try SettingsMerger.load(path: p)
    }

    private func unwire(_ p: String) throws -> [String: Any] {
        let all = HookWriterRegistry.writers(for: "claude")
        var proposed = try SettingsMerger.load(path: p)
        for w in all {
            proposed = try SettingsMerger.remove(proposed, event: w.hookEvent, isMine: w.isMine)
        }
        try SettingsMerger.write(proposed, to: p)
        return try SettingsMerger.load(path: p)
    }

    func testWireRegistersBothEvents() throws {
        let s = try wire(path(), command: "/bin/pesterm", approvals: true)
        // Approvals ON => the Notification command carries NO suppress flag, and its
        // matcher OMITS permission_prompt (the approval hook owns that event → no double
        // banner).
        XCTAssertEqual(commands(s, event: "Notification"),
                       ["'/bin/pesterm' --adapter claude"])
        XCTAssertEqual(matcher(s, event: "Notification"),
                       ClaudeHookWriter.handledNotificationTypesNoPermission)
        XCTAssertEqual(commands(s, event: "PermissionRequest"),
                       ["'/bin/pesterm' --adapter claude-permission"])
    }

    // isMine recognizes a matcher-bearing Notification entry (re-wire/unwire must still
    // find and replace/remove it).
    func testIsMineMatchesMatcherEntry() {
        let entry = ClaudeHookWriter(matcher: ClaudeHookWriter.handledNotificationTypesNoPermission)
            .makeEntry(command: "/bin/pesterm", sound: nil)
        XCTAssertTrue(ClaudeHookWriter().isMine(entry))
    }

    func testNoApprovalsRegistersOnlyNotification() throws {
        let s = try wire(path(), command: "/bin/pesterm", approvals: false)
        XCTAssertEqual(commands(s, event: "Notification"),
                       ["'/bin/pesterm' --adapter claude"])
        // Approvals OFF => the matcher INCLUDES permission_prompt (info hook owns it).
        XCTAssertEqual(matcher(s, event: "Notification"),
                       ClaudeHookWriter.handledNotificationTypes)
        XCTAssertTrue(commands(s, event: "PermissionRequest").isEmpty)
    }

    // Codex P2: --no-approvals against settings that ALREADY contain the approval hook
    // must REMOVE it (not leave it active), while keeping the Notification hook.
    func testNoApprovalsRemovesExistingApprovalHook() throws {
        let p = path()
        try wire(p, command: "/bin/pesterm", approvals: true)   // both hooks present
        XCTAssertFalse(commands(try SettingsMerger.load(path: p), event: "PermissionRequest").isEmpty,
                       "precondition: approval hook is wired")

        let s = try wire(p, command: "/bin/pesterm", approvals: false)   // now disable
        XCTAssertEqual(commands(s, event: "Notification"),
                       ["'/bin/pesterm' --adapter claude"], "Notification hook stays")
        XCTAssertTrue(commands(s, event: "PermissionRequest").isEmpty,
                      "disable must REMOVE the previously-wired approval hook")
    }

    func testUnwireRemovesBoth() throws {
        let p = path()
        try wire(p, command: "/bin/pesterm", approvals: true)
        let s = try unwire(p)
        // Both pruned → hooks empty → hooks key removed.
        XCTAssertNil(s["hooks"], "both events removed; empty hooks pruned")
    }

    func testIdempotentRewireIsNoOp() throws {
        let p = path()
        try wire(p, command: "/bin/pesterm", approvals: true)
        let first = try Data(contentsOf: URL(fileURLWithPath: p))
        // Re-wire identically via the same path => byte-identical, no churn.
        try wire(p, command: "/bin/pesterm", approvals: true)
        let second = try Data(contentsOf: URL(fileURLWithPath: p))
        XCTAssertEqual(first, second, "re-wire same path is byte-identical (no churn)")
    }

    func testWirePreservesUnrelatedHooks() throws {
        let p = path()
        let seed: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/bin/audit"]]]
                ]
            ],
            "someKey": true
        ]
        try SettingsMerger.write(seed, to: p)
        let s = try wire(p, command: "/bin/pesterm", approvals: true)
        XCTAssertNotNil((s["hooks"] as? [String: Any])?["PreToolUse"])
        XCTAssertNotNil(s["someKey"])
        XCTAssertEqual(commands(s, event: "PermissionRequest"),
                       ["'/bin/pesterm' --adapter claude-permission"])
    }
}
