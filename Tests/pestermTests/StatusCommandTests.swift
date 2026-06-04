import XCTest
@testable import pesterm

final class StatusCommandTests: XCTestCase {

    // commandPath unwraps a leading single-quoted path (current format).
    func testCommandPathUnquotesSingle() {
        XCTAssertEqual(
            StatusCommand.commandPath("'/Users/Jane Doe/.local/bin/pesterm' --adapter claude"),
            "/Users/Jane Doe/.local/bin/pesterm")
    }

    // commandPath reverses the `'\''` escape in a single-quoted path.
    func testCommandPathUnquotesSingleWithEscape() {
        // Path /a/b'c is wired as '/a/b'\''c'.
        XCTAssertEqual(
            StatusCommand.commandPath("'/a/b'\\''c' --adapter claude"),
            "/a/b'c")
    }

    // commandPath leaves a `$`-bearing single-quoted path literal (no expansion).
    func testCommandPathDollarLiteral() {
        XCTAssertEqual(
            StatusCommand.commandPath("'/tmp/a$b/pesterm' --adapter claude"),
            "/tmp/a$b/pesterm")
    }

    // commandPath still unwraps a leading double-quoted path (legacy format).
    func testCommandPathUnquotes() {
        XCTAssertEqual(
            StatusCommand.commandPath("\"/Users/Jane Doe/.local/bin/pesterm\" --adapter claude"),
            "/Users/Jane Doe/.local/bin/pesterm")
    }

    // commandPath falls back to the first token for legacy unquoted commands.
    func testCommandPathLegacyUnquoted() {
        XCTAssertEqual(
            StatusCommand.commandPath("/usr/local/bin/pesterm --adapter claude"),
            "/usr/local/bin/pesterm")
    }

    // execTarget parses a single-quoted exec line of the wrapper script (current).
    func testExecTargetSingleQuoted() {
        let wrapper = """
        #!/bin/bash
        exec '/Users/Jane Doe/.local/share/pesterm/pesterm.app/Contents/MacOS/pesterm' "$@"
        """
        XCTAssertEqual(
            StatusCommand.execTarget(inWrapper: wrapper),
            "/Users/Jane Doe/.local/share/pesterm/pesterm.app/Contents/MacOS/pesterm")
    }

    // execTarget parses a double-quoted exec line of the wrapper script (legacy).
    func testExecTargetQuoted() {
        let wrapper = """
        #!/bin/bash
        exec "/Users/Jane Doe/.local/share/pesterm/pesterm.app/Contents/MacOS/pesterm" "$@"
        """
        XCTAssertEqual(
            StatusCommand.execTarget(inWrapper: wrapper),
            "/Users/Jane Doe/.local/share/pesterm/pesterm.app/Contents/MacOS/pesterm")
    }

    // leadsIntoBundle recognizes a path inside pesterm.app.
    func testLeadsIntoBundle() {
        XCTAssertTrue(StatusCommand.leadsIntoBundle(
            "/x/share/pesterm/pesterm.app/Contents/MacOS/pesterm"))
        XCTAssertFalse(StatusCommand.leadsIntoBundle("/usr/local/bin/pesterm"))
    }

    // binEntryTarget reads a wrapper script (regular file) and returns its exec target.
    func testBinEntryTargetReadsWrapper() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pesterm-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let inner = "/tmp/share/pesterm/pesterm.app/Contents/MacOS/pesterm"
        let entry = dir.appendingPathComponent("pesterm")
        let wrapper = "#!/bin/bash\nexec \"\(inner)\" \"$@\"\n"
        try wrapper.write(to: entry, atomically: true, encoding: .utf8)

        let target = StatusCommand.binEntryTarget(entry.path)
        XCTAssertEqual(target, inner)
        XCTAssertTrue(StatusCommand.leadsIntoBundle(target))
    }

    // binEntryTarget resolves a symlink (legacy layout).
    func testBinEntryTargetResolvesSymlink() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pesterm-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let realFile = dir.appendingPathComponent("real-pesterm")
        try "x".write(to: realFile, atomically: true, encoding: .utf8)
        let link = dir.appendingPathComponent("pesterm")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)

        let target = StatusCommand.binEntryTarget(link.path)
        XCTAssertTrue(target.hasSuffix("real-pesterm"))
    }
}
