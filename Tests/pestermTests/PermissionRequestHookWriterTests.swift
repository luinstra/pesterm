import XCTest
@testable import pesterm

final class PermissionRequestHookWriterTests: XCTestCase {

    let writer = PermissionRequestHookWriter()
    var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pesterm-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func path() -> String { scratch.appendingPathComponent("settings.json").path }

    private func entries(_ s: [String: Any]) -> [Any] {
        ((s["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any]) ?? []
    }

    private func commands(in entries: [Any]) -> [String] {
        entries.flatMap { entry -> [String] in
            guard let d = entry as? [String: Any], let hooks = d["hooks"] as? [Any] else { return [] }
            return hooks.compactMap { ($0 as? [String: Any])?["command"] as? String }
        }
    }

    // identity
    func testAgentAndEvent() {
        XCTAssertEqual(writer.agentName, "claude")
        XCTAssertEqual(writer.hookEvent, "PermissionRequest")
    }

    // makeEntry emits the permission adapter flag, NO --sound / --approve-ui, even when
    // a sound is passed (it is ignored).
    func testMakeEntryIgnoresSoundAndHasNoApproveUI() {
        let entry = writer.makeEntry(command: "/bin/pesterm", sound: "Glass")
        let cmds = commands(in: [entry])
        XCTAssertEqual(cmds, ["'/bin/pesterm' --adapter claude-permission"])
        XCTAssertFalse(cmds[0].contains("--sound"))
        XCTAssertFalse(cmds[0].contains("--approve-ui"))
    }

    // bare command name stays unquoted, reusing ClaudeHookWriter.shellArg.
    func testBareCommandUnquoted() throws {
        let current = try SettingsMerger.load(path: path())
        let merged = try SettingsMerger.upsert(current, event: writer.hookEvent,
                                               isMine: writer.isMine,
                                               entry: writer.makeEntry(command: "pesterm"))
        try SettingsMerger.write(merged, to: path())
        let s = try SettingsMerger.load(path: path())
        XCTAssertEqual(commands(in: entries(s)), ["pesterm --adapter claude-permission"])
    }

    // isMine matches our flag and NOT the plain Notification flag.
    func testIsMineBoundary() {
        let mine: [String: Any] = ["hooks": [["type": "command",
            "command": "'/bin/pesterm' --adapter claude-permission"]]]
        let notMine: [String: Any] = ["hooks": [["type": "command",
            "command": "'/bin/pesterm' --adapter claude"]]]
        XCTAssertTrue(writer.isMine(mine))
        XCTAssertFalse(writer.isMine(notMine))
    }
}
