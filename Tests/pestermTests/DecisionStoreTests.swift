import XCTest
@testable import pesterm

/// The cross-process decision handoff. Uses a unique temp dir per test so it never touches
/// the real `~/.local/state/pesterm/decisions`.
final class DecisionStoreTests: XCTestCase {

    private func tempDir() -> String {
        NSTemporaryDirectory() + "pesterm-dectest-" + ProcessInfo.processInfo.globallyUniqueString
    }

    func testWriteThenTakeRoundtrip() {
        let dir = tempDir()
        DecisionStore.write(.allow, forId: "abc", dir: dir)
        XCTAssertEqual(DecisionStore.take(id: "abc", dir: dir), .allow)
    }

    func testTakeRemovesSoSecondTakeIsNil() {
        let dir = tempDir()
        DecisionStore.write(.deny, forId: "x", dir: dir)
        XCTAssertEqual(DecisionStore.take(id: "x", dir: dir), .deny)
        XCTAssertNil(DecisionStore.take(id: "x", dir: dir), "take must remove the file")
    }

    func testTakeMissingIsNil() {
        XCTAssertNil(DecisionStore.take(id: "never-written", dir: tempDir()))
    }

    func testTimeoutWritesNothing() {
        let dir = tempDir()
        DecisionStore.write(.timeout, forId: "t", dir: dir)
        XCTAssertNil(DecisionStore.take(id: "t", dir: dir), "timeout has no decision to hand off")
    }

    // The core property the handoff relies on: distinct ids never collide, so a process
    // only ever picks up the decision meant for IT.
    func testDistinctIdsDoNotCollide() {
        let dir = tempDir()
        DecisionStore.write(.allow, forId: "ALPHA", dir: dir)
        DecisionStore.write(.deny, forId: "BRAVO", dir: dir)
        XCTAssertEqual(DecisionStore.take(id: "ALPHA", dir: dir), .allow)
        XCTAssertEqual(DecisionStore.take(id: "BRAVO", dir: dir), .deny)
    }

    func testWriteOverwritesStaleForSameId() {
        let dir = tempDir()
        DecisionStore.write(.allow, forId: "id", dir: dir)
        DecisionStore.write(.deny, forId: "id", dir: dir)
        XCTAssertEqual(DecisionStore.take(id: "id", dir: dir), .deny)
    }
}
