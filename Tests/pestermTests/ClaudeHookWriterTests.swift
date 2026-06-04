import XCTest
@testable import pesterm

final class ClaudeHookWriterTests: XCTestCase {

    let writer = ClaudeHookWriter()
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pesterm-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func path() -> String { scratch.appendingPathComponent("settings.json").path }

    // Wire helper: load → upsert → write, returns the reparsed settings.
    @discardableResult
    private func wire(_ p: String, command: String) throws -> [String: Any] {
        let current = try SettingsMerger.load(path: p)
        let merged = try SettingsMerger.upsert(current, event: writer.hookEvent,
                                               isMine: writer.isMine,
                                               entry: writer.makeEntry(command: command))
        try SettingsMerger.write(merged, to: p)
        return try SettingsMerger.load(path: p)
    }

    private func unwire(_ p: String) throws -> [String: Any] {
        let current = try SettingsMerger.load(path: p)
        let merged = try SettingsMerger.remove(current, event: writer.hookEvent, isMine: writer.isMine)
        try SettingsMerger.write(merged, to: p)
        return try SettingsMerger.load(path: p)
    }

    private func notificationEntries(_ s: [String: Any]) -> [Any] {
        ((s["hooks"] as? [String: Any])?["Notification"] as? [Any]) ?? []
    }

    private func commands(in entries: [Any]) -> [String] {
        entries.flatMap { entry -> [String] in
            guard let d = entry as? [String: Any], let hooks = d["hooks"] as? [Any] else { return [] }
            return hooks.compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    // 1. wire into empty/missing → exactly one matcher-less entry with --adapter claude.
    func testWireIntoMissingCreatesSingleEntry() throws {
        let s = try wire(path(), command: "/usr/local/bin/pesterm")
        let entries = notificationEntries(s)
        XCTAssertEqual(entries.count, 1)
        // Matcher-less: the entry has NO "matcher" key.
        XCTAssertNil((entries[0] as? [String: Any])?["matcher"])
        XCTAssertEqual(commands(in: entries), ["'/usr/local/bin/pesterm' --adapter claude"])
    }

    // 2. idempotent re-wire (same path) → identical output.
    func testIdempotentRewire() throws {
        let p = path()
        try wire(p, command: "/usr/local/bin/pesterm")
        let first = try Data(contentsOf: URL(fileURLWithPath: p))

        // Re-wire: caller would detect no-op; here confirm the merged result is equal.
        let current = try SettingsMerger.load(path: p)
        let merged = try SettingsMerger.upsert(current, event: writer.hookEvent,
                                               isMine: writer.isMine,
                                               entry: writer.makeEntry(command: "/usr/local/bin/pesterm"))
        XCTAssertTrue(Wiring.equalSettings(current, merged), "re-wire same path is a no-op")

        // Writing again yields byte-identical file and no extra backup.
        try SettingsMerger.write(merged, to: p)
        let second = try Data(contentsOf: URL(fileURLWithPath: p))
        XCTAssertEqual(first, second)
    }

    // 3. re-wire with a DIFFERENT path → stale removed, single canonical at new path.
    func testRewireNewPathRemovesStale() throws {
        let p = path()
        try wire(p, command: "/old/path/pesterm")
        let s = try wire(p, command: "/new/path/pesterm")
        let cmds = commands(in: notificationEntries(s))
        XCTAssertEqual(cmds, ["'/new/path/pesterm' --adapter claude"])
    }

    // 4. multiple stale isMine entries → ALL removed, single canonical appended.
    func testMultipleStaleEntriesAllRemoved() throws {
        let p = path()
        // Hand-build settings with two stale ours entries + write directly.
        let seed: [String: Any] = [
            "hooks": [
                "Notification": [
                    ["hooks": [["type": "command", "command": "/a/pesterm --adapter claude"]]],
                    ["hooks": [["type": "command", "command": "/b/pesterm --adapter claude"]]]
                ]
            ]
        ]
        try SettingsMerger.write(seed, to: p)
        XCTAssertEqual(notificationEntries(try SettingsMerger.load(path: p)).count, 2)

        let s = try wire(p, command: "/canonical/pesterm")
        let entries = notificationEntries(s)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(commands(in: entries), ["'/canonical/pesterm' --adapter claude"])
    }

    // 5. preserves unrelated hooks: PreToolUse + a non-ours Notification matcher survive
    //    a wire/unwire cycle.
    func testPreservesUnrelatedHooks() throws {
        let p = path()
        let seed: [String: Any] = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "/usr/bin/audit"]]]
                ],
                "Notification": [
                    ["matcher": "Stop", "hooks": [["type": "command", "command": "/other/tool --notify"]]]
                ]
            ],
            "someUnrelatedKey": ["nested": true]
        ]
        try SettingsMerger.write(seed, to: p)

        // Wire ours in.
        let wired = try wire(p, command: "/bin/pesterm")
        // PreToolUse intact.
        XCTAssertNotNil((wired["hooks"] as? [String: Any])?["PreToolUse"])
        // Unrelated key intact.
        XCTAssertNotNil(wired["someUnrelatedKey"])
        // Both the foreign Notification matcher and ours present.
        let wiredCmds = commands(in: notificationEntries(wired))
        XCTAssertTrue(wiredCmds.contains("/other/tool --notify"))
        XCTAssertTrue(wiredCmds.contains("'/bin/pesterm' --adapter claude"))

        // Unwire ours.
        let unwired = try unwire(p)
        XCTAssertNotNil((unwired["hooks"] as? [String: Any])?["PreToolUse"])
        XCTAssertNotNil(unwired["someUnrelatedKey"])
        let unwiredCmds = commands(in: notificationEntries(unwired))
        XCTAssertEqual(unwiredCmds, ["/other/tool --notify"], "only the foreign matcher survives")
    }

    // 6. unwire removes ONLY ours; foreign Notification matcher + PreToolUse survive.
    //    When ours was the only Notification entry, the Notification key is pruned.
    func testUnwireRemovesOnlyOursAndPrunesWhenSole() throws {
        let p = path()
        try wire(p, command: "/bin/pesterm")
        let unwired = try unwire(p)
        // Ours was sole Notification entry → Notification key pruned, and since hooks
        // becomes empty, hooks key pruned too.
        XCTAssertNil(unwired["hooks"], "empty hooks pruned after removing the sole entry")
    }

    // 7. hand-edited entry mentioning claude but NOT --adapter claude → NOT matched.
    func testHandEditedNonAdapterEntryPreserved() throws {
        let p = path()
        let seed: [String: Any] = [
            "hooks": [
                "Notification": [
                    ["hooks": [["type": "command", "command": "/my/claude-helper.sh notify"]]]
                ]
            ]
        ]
        try SettingsMerger.write(seed, to: p)

        // isMine must NOT match it.
        let entries = notificationEntries(try SettingsMerger.load(path: p))
        XCTAssertFalse(writer.isMine(entries[0]))

        // Wire ours: the hand-edited entry survives alongside ours.
        let wired = try wire(p, command: "/bin/pesterm")
        let cmds = commands(in: notificationEntries(wired))
        XCTAssertTrue(cmds.contains("/my/claude-helper.sh notify"))
        XCTAssertTrue(cmds.contains("'/bin/pesterm' --adapter claude"))

        // Unwire ours: the hand-edited entry remains.
        let unwired = try unwire(p)
        let after = commands(in: notificationEntries(unwired))
        XCTAssertEqual(after, ["/my/claude-helper.sh notify"])
    }

    // 8. a path containing spaces is single-quoted in the command.
    func testSpacePathIsQuoted() throws {
        let s = try wire(path(), command: "/Users/Jane Doe/.local/bin/pesterm")
        XCTAssertEqual(commands(in: notificationEntries(s)),
                       ["'/Users/Jane Doe/.local/bin/pesterm' --adapter claude"])
    }

    // 9. isMine matches the new single-quoted form, the legacy double-quoted form,
    //    and legacy unquoted entries.
    func testIsMineMatchesQuotedAndUnquoted() {
        let single: [String: Any] = ["hooks": [["type": "command",
            "command": "'/path with space/pesterm' --adapter claude"]]]
        let doubleQuoted: [String: Any] = ["hooks": [["type": "command",
            "command": "\"/path with space/pesterm\" --adapter claude"]]]
        let unquoted: [String: Any] = ["hooks": [["type": "command",
            "command": "/path/pesterm --adapter claude"]]]
        XCTAssertTrue(writer.isMine(single))
        XCTAssertTrue(writer.isMine(doubleQuoted))
        XCTAssertTrue(writer.isMine(unquoted))
    }

    // 10. POSIX single-quote escaping is injection-proof for every shell metachar.
    //     The wired command must wrap the path in single quotes so that `$(...)`,
    //     backticks, `$VAR`, `"`, `\`, spaces are all inert; the only escaped char
    //     is `'` itself (closed-reopened as '\'').
    func testShellQuoteIsInjectionProof() {
        // Command substitution.
        XCTAssertEqual(ClaudeHookWriter.shellQuote("/tmp/a$(rm -rf ~)/pesterm"),
                       "'/tmp/a$(rm -rf ~)/pesterm'")
        // Backticks.
        XCTAssertEqual(ClaudeHookWriter.shellQuote("/tmp/a`whoami`/pesterm"),
                       "'/tmp/a`whoami`/pesterm'")
        // Variable expansion.
        XCTAssertEqual(ClaudeHookWriter.shellQuote("/tmp/$HOME/pesterm"),
                       "'/tmp/$HOME/pesterm'")
        // Double quote — left literal inside single quotes (NOT escaped).
        XCTAssertEqual(ClaudeHookWriter.shellQuote("/tmp/a\"b/pesterm"),
                       "'/tmp/a\"b/pesterm'")
        // Backslash — left literal inside single quotes (NOT escaped).
        XCTAssertEqual(ClaudeHookWriter.shellQuote("/tmp/a\\b/pesterm"),
                       "'/tmp/a\\b/pesterm'")
        // Single quote — the one char that MUST be escaped: '\''.
        XCTAssertEqual(ClaudeHookWriter.shellQuote("/a/b'c"),
                       "'/a/b'\\''c'")
    }

    // 11. End-to-end: a `$`-bearing path wired into a real settings file produces a
    //     single-quoted command with NO unescaped `$`/backtick/`"` a shell would eval.
    func testWireDollarPathIsSingleQuoted() throws {
        let s = try wire(path(), command: "/tmp/a$b/pesterm")
        let cmds = commands(in: notificationEntries(s))
        XCTAssertEqual(cmds, ["'/tmp/a$b/pesterm' --adapter claude"])
        // The `$` sits inside single quotes (after a leading `'`, before any closing
        // `'`), so a shell will not expand it.
        let cmd = cmds[0]
        XCTAssertTrue(cmd.hasPrefix("'"), "command must open with a single quote")
    }

    // Registry sanity.
    func testRegistry() {
        XCTAssertNotNil(HookWriterRegistry.writer(for: "claude"))
        XCTAssertNotNil(HookWriterRegistry.writer(for: "CLAUDE"))
        XCTAssertNil(HookWriterRegistry.writer(for: "codex"))
        XCTAssertEqual(HookWriterRegistry.supportedAgents, ["claude"])
    }
}
