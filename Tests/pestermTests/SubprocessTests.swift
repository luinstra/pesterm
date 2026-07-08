import XCTest
@testable import pesterm

final class SubprocessTests: XCTestCase {

    // MARK: - Subprocess.run

    func testEchoValueReturned() {
        let result = Subprocess.run(exe: "/bin/echo", args: ["hello"], timeout: 5)
        XCTAssertEqual(result?.status, 0)
        XCTAssertEqual(result?.stdout, "hello\n")
    }

    func testTimeoutReturnsNilWithinTolerance() {
        let start = Date()
        let result = Subprocess.run(exe: "/bin/sleep", args: ["2"], timeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(result)
        // 0.2s box + 0.2s reap grace; generous ceiling for CI jitter — the point is
        // "far less than the child's 2s sleep".
        XCTAssertLessThan(elapsed, 1.5)
    }

    func testNonZeroExitStatusSurfaced() {
        // Subprocess SURFACES the status (TmuxClient consumers need it);
        // FocusProbeClient ignores it per D6 (tested below).
        let result = Subprocess.run(exe: "/bin/sh", args: ["-c", "echo out; exit 3"],
                                    timeout: 5)
        XCTAssertEqual(result?.status, 3)
        XCTAssertEqual(result?.stdout, "out\n")
    }

    func testLaunchFailureReturnsNil() {
        XCTAssertNil(Subprocess.run(exe: "/no/such/binary", args: [], timeout: 1))
    }

    // MARK: - FocusProbeClient child-failure contract (D6: stdout content ONLY)

    func testValueSingleLineTrimmed() {
        XCTAssertEqual(FocusProbeClient.value(fromChildStdout: "ABC-123\n"), "ABC-123")
        XCTAssertEqual(FocusProbeClient.value(fromChildStdout: "  ABC-123  \n"), "ABC-123")
    }

    func testValueEmptyIsNil() {
        XCTAssertNil(FocusProbeClient.value(fromChildStdout: ""))
    }

    func testValueWhitespaceOnlyIsNil() {
        XCTAssertNil(FocusProbeClient.value(fromChildStdout: " \n\t \n"))
    }

    func testValueMultiLineIsNil() {
        XCTAssertNil(FocusProbeClient.value(fromChildStdout: "line1\nline2\n"))
        // A cwd containing an embedded newline is pathological output, not a value.
        XCTAssertNil(FocusProbeClient.value(fromChildStdout: "/tmp/a\n/tmp/b"))
    }

    func testValueWithNonZeroExitIsStillAValue() {
        // The child's exit code is IGNORED — stdout content is the only discriminator.
        XCTAssertEqual(FocusProbeClient.value(fromRunResult: (status: 3, stdout: "GUID-1\n")),
                       "GUID-1")
    }

    func testValueFromNilRunResultIsNil() {
        // Launch failure / TIMEOUT (child SIGTERMed) → nil. This is readValue's timeout
        // leg: an end-to-end readValue timeout test is impractical (it re-executes the
        // RUNNING binary — the xctest runner), so the leg is covered compositionally by
        // testTimeoutReturnsNilWithinTolerance (Subprocess returns nil at the deadline)
        // + this mapping.
        XCTAssertNil(FocusProbeClient.value(fromRunResult: nil))
    }

    func testValueFromRunResultAppliesStdoutContract() {
        XCTAssertNil(FocusProbeClient.value(fromRunResult: (status: 0, stdout: "")))
        XCTAssertNil(FocusProbeClient.value(fromRunResult: (status: 0, stdout: "a\nb\n")))
        XCTAssertEqual(FocusProbeClient.value(fromRunResult: (status: 0, stdout: "v\n")), "v")
    }
}
