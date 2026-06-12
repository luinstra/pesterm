import XCTest
@testable import pesterm

/// `configure` must not stomp an already-wired (possibly hand-edited) setup on reinstall.
final class ConfigurePreserveTests: XCTestCase {

    // MARK: shouldPreserveExisting (the decision)

    func testPreservesWhenWiredAndNoReconfigureSignal() {
        XCTAssertTrue(ConfigureCommand.shouldPreserveExisting(
            alreadyWired: true, force: false, noApprovals: false, soundProvided: false))
    }

    func testDoesNotPreserveWhenNotWired() {
        XCTAssertFalse(ConfigureCommand.shouldPreserveExisting(
            alreadyWired: false, force: false, noApprovals: false, soundProvided: false))
    }

    func testForceOverridesPreserve() {
        XCTAssertFalse(ConfigureCommand.shouldPreserveExisting(
            alreadyWired: true, force: true, noApprovals: false, soundProvided: false))
    }

    func testExplicitNoApprovalsOverridesPreserve() {
        XCTAssertFalse(ConfigureCommand.shouldPreserveExisting(
            alreadyWired: true, force: false, noApprovals: true, soundProvided: false))
    }

    func testExplicitSoundOverridesPreserve() {
        XCTAssertFalse(ConfigureCommand.shouldPreserveExisting(
            alreadyWired: true, force: false, noApprovals: false, soundProvided: true))
    }

    // MARK: isAgentWired (detection)

    func testEmptySettingsNotWired() {
        let writers = HookWriterRegistry.writers(for: "claude")
        XCTAssertFalse(ConfigureCommand.isAgentWired([:], writers: writers))
    }

    func testPestermEntryIsWired() {
        let writers = HookWriterRegistry.writers(for: "claude")
        let claude = writers.first { $0 is ClaudeHookWriter }!
        let entry = claude.makeEntry(command: "pesterm", sound: nil)
        let settings: [String: Any] = ["hooks": [claude.hookEvent: [entry]]]
        XCTAssertTrue(ConfigureCommand.isAgentWired(settings, writers: writers))
    }

    func testForeignEntryIsNotWired() {
        let writers = HookWriterRegistry.writers(for: "claude")
        let claude = writers.first { $0 is ClaudeHookWriter }!
        let settings: [String: Any] = [
            "hooks": [claude.hookEvent: [["type": "command", "command": "some-other-tool"]]]
        ]
        XCTAssertFalse(ConfigureCommand.isAgentWired(settings, writers: writers),
                       "someone else's hook must not count as pesterm being wired")
    }
}
