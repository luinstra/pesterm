import XCTest
import UserNotifications
@testable import pesterm

final class PermissionFlowTests: XCTestCase {

    // MARK: decision(forActionIdentifier:)

    func testDecisionApprove() {
        XCTAssertEqual(PermissionFlow.decision(forActionIdentifier: "pesterm.approve"), .allow)
    }

    func testDecisionDeny() {
        XCTAssertEqual(PermissionFlow.decision(forActionIdentifier: "pesterm.deny"), .deny)
    }

    // Default / nil / unknown -> nil = body click = reveal-and-keep-waiting.
    func testDecisionBodyClickIsNil() {
        XCTAssertNil(PermissionFlow.decision(
            forActionIdentifier: UNNotificationDefaultActionIdentifier))
        XCTAssertNil(PermissionFlow.decision(forActionIdentifier: nil))
        XCTAssertNil(PermissionFlow.decision(forActionIdentifier: "something.else"))
    }

    // MARK: timeout constant

    func testTimeoutIs120AndBelowMaxLifetime() {
        XCTAssertEqual(PermissionFlow.timeoutSeconds, 120)
        XCTAssertLessThan(PermissionFlow.timeoutSeconds,
                          UNUserNotificationBackend.maxLifetimeSeconds)
    }

    // MARK: emission — every exit code 0

    func testEmissionAllow() {
        let e = PermissionFlow.emission(for: .allow)
        XCTAssertEqual(e.stdout, PermissionDecision.outputJSON(for: .allow))
        XCTAssertEqual(e.exitCode, 0)
    }

    func testEmissionDeny() {
        let e = PermissionFlow.emission(for: .deny)
        XCTAssertEqual(e.stdout, PermissionDecision.outputJSON(for: .deny))
        XCTAssertEqual(e.exitCode, 0)
    }

    func testEmissionTimeout() {
        let e = PermissionFlow.emission(for: .timeout)
        XCTAssertNil(e.stdout)
        XCTAssertEqual(e.exitCode, 0)
    }

    // MARK: one-shot gate — simulated timer-after-tap does NOT double-emit

    func testTimerAfterTapDoesNotDoubleEmit() {
        let gate = ResolvedGate()
        // Action tap wins.
        XCTAssertTrue(gate.tryResolve())
        // The late fail-safe timer must lose.
        XCTAssertFalse(gate.tryResolve())
    }

    // MARK: AdapterDispatch routing

    func testRouteClaudeIsInfo() {
        XCTAssertEqual(AdapterDispatch.route(for: "claude"), .info)
    }

    func testRouteClaudePermissionIsPermission() {
        XCTAssertEqual(AdapterDispatch.route(for: "claude-permission"), .permission)
    }

    func testRouteUnknown() {
        XCTAssertEqual(AdapterDispatch.route(for: "codex"), .unknown)
        XCTAssertEqual(AdapterDispatch.route(for: ""), .unknown)
        XCTAssertEqual(AdapterDispatch.route(for: "claude-x"), .unknown)
    }
}
