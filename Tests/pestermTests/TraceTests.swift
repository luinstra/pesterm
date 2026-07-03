import XCTest
@testable import pesterm

/// Tests for the trace-path resolver — the marker gate is the load-bearing mechanism for
/// live-hook evidence capture; if it silently breaks the whole investigation fails. The
/// resolution logic is a PURE helper (`Trace.resolvePath(env:markerExists:)`) so it can be
/// exercised without touching the real env or filesystem.
final class TraceTests: XCTestCase {

    // PESTERM_TRACE (non-empty) wins — even when the marker would also match.
    func testEnvPathWinsEvenWhenMarkerMatches() {
        let path = Trace.resolvePath(
            env: ["PESTERM_TRACE": "/custom/trace.log", "HOME": "/home/u"],
            markerExists: { _ in true }   // marker present, but env must win
        )
        XCTAssertEqual(path, "/custom/trace.log")
    }

    // An empty PESTERM_TRACE is ignored; falls through to the marker gate.
    func testEmptyEnvPathFallsThroughToMarker() {
        let path = Trace.resolvePath(
            env: ["PESTERM_TRACE": "", "HOME": "/home/u"],
            markerExists: { $0 == "/home/u/.pesterm-debug" }
        )
        XCTAssertEqual(path, "/home/u/.pesterm-debug.log")
    }

    // Marker present, no env → the derived .log path under HOME.
    func testMarkerPresentNoEnvYieldsLogPath() {
        let path = Trace.resolvePath(
            env: ["HOME": "/home/u"],
            markerExists: { $0 == "/home/u/.pesterm-debug" }
        )
        XCTAssertEqual(path, "/home/u/.pesterm-debug.log")
    }

    // Neither env nor marker → nil (tracing off).
    func testNeitherEnvNorMarkerYieldsNil() {
        let path = Trace.resolvePath(
            env: ["HOME": "/home/u"],
            markerExists: { _ in false }
        )
        XCTAssertNil(path)
    }

    // HOME unset → nil even if a marker check would match (no crash, no path).
    func testHomeUnsetYieldsNil() {
        let path = Trace.resolvePath(
            env: [:],
            markerExists: { _ in true }
        )
        XCTAssertNil(path)
    }

    // Empty HOME is treated as unset → nil.
    func testEmptyHomeYieldsNil() {
        let path = Trace.resolvePath(
            env: ["HOME": ""],
            markerExists: { _ in true }
        )
        XCTAssertNil(path)
    }
}
