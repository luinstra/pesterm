import XCTest
@testable import pesterm

/// Asserts on `makeProcess` output only — no test launches audio. The fd-isolation
/// assertions ARE the guard on Claude's decision channel: on the permission path the
/// hook's stdout is the decision channel, and an afplay child inheriting it could hold
/// the pipe open or write into it.
final class DetachedSoundTests: XCTestCase {

    func testMakeProcessExecutableAndArgs() {
        let proc = DetachedSound.makeProcess(filePath: "/System/Library/Sounds/Glass.aiff")
        XCTAssertEqual(proc.executableURL?.path, "/usr/bin/afplay")
        XCTAssertEqual(proc.arguments, ["/System/Library/Sounds/Glass.aiff"])
    }

    func testMakeProcessIsolatesAllStdio() {
        let proc = DetachedSound.makeProcess(filePath: "/tmp/x.aiff")
        XCTAssertTrue(proc.standardOutput as? FileHandle === FileHandle.nullDevice,
                      "stdout must be nulled — it is Claude's decision channel")
        XCTAssertTrue(proc.standardError as? FileHandle === FileHandle.nullDevice)
        XCTAssertTrue(proc.standardInput as? FileHandle === FileHandle.nullDevice)
    }

    func testPlayWithNilNameIsNoOp() {
        // Must not throw, block, or crash.
        DetachedSound.play(name: nil)
    }

    func testPlayWithUnresolvableNameIsNoOp() {
        DetachedSound.play(name: "DefinitelyNotARealSound_pesterm_xyz")
    }
}
