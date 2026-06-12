import XCTest
import ArgumentParser
@testable import pesterm

/// The `--timeout` override: clamp logic for both paths + the `post` option wiring.
final class TimeoutOverrideTests: XCTestCase {

    // MARK: permission fail-safe clamp (must stay under Claude's ~600s hook timeout)

    func testPermissionDefaultWhenAbsentOrNonPositive() {
        XCTAssertEqual(PermissionFlow.effectiveTimeout(override: nil), PermissionFlow.timeoutSeconds)
        XCTAssertEqual(PermissionFlow.effectiveTimeout(override: 0), PermissionFlow.timeoutSeconds)
        XCTAssertEqual(PermissionFlow.effectiveTimeout(override: -5), PermissionFlow.timeoutSeconds)
    }

    func testPermissionClampsHighToMax() {
        XCTAssertEqual(PermissionFlow.effectiveTimeout(override: 9999), PermissionFlow.maxTimeoutSeconds)
    }

    func testPermissionClampsLowToMin() {
        XCTAssertEqual(PermissionFlow.effectiveTimeout(override: 1), PermissionFlow.minTimeoutSeconds)
    }

    func testPermissionPassesThroughInRange() {
        XCTAssertEqual(PermissionFlow.effectiveTimeout(override: 90), 90)
    }

    // MARK: info hard-cap clamp (floored; no hard upper)

    func testInfoDefaultWhenAbsentOrNonPositive() {
        XCTAssertEqual(UNUserNotificationBackend.effectiveInfoCap(override: nil),
                       UNUserNotificationBackend.maxLifetimeSeconds)
        XCTAssertEqual(UNUserNotificationBackend.effectiveInfoCap(override: -1),
                       UNUserNotificationBackend.maxLifetimeSeconds)
    }

    func testInfoFloorsTooSmall() {
        XCTAssertEqual(UNUserNotificationBackend.effectiveInfoCap(override: 1),
                       UNUserNotificationBackend.minInfoCapSeconds)
    }

    func testInfoPassesThroughLargeValue() {
        XCTAssertEqual(UNUserNotificationBackend.effectiveInfoCap(override: 300), 300)
    }

    // MARK: `post --timeout` wiring

    func testPostCommandParsesTimeoutOntoRequest() throws {
        let cmd = try PostCommand.parse(["--message", "hi", "--timeout", "45"])
        XCTAssertEqual(cmd.makeRequest().lifetimeSeconds, 45)
    }

    func testPostCommandNoTimeoutLeavesNil() throws {
        let cmd = try PostCommand.parse(["--message", "hi"])
        XCTAssertNil(cmd.makeRequest().lifetimeSeconds)
    }
}
