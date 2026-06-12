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

    // NOTE: adapter routing moved from AdapterDispatch to AdapterRegistry — see
    // AdapterRegistryTests.

    // MARK: tap routing (multi-process handoff)

    func testRouteOwnApproveResolvesOwn() {
        XCTAssertEqual(
            PermissionFlow.route(responseId: "me", myId: "me",
                                 actionId: PermissionFlow.approveActionIdentifier),
            .resolveOwn(.allow))
    }

    func testRouteOwnDenyResolvesOwn() {
        XCTAssertEqual(
            PermissionFlow.route(responseId: "me", myId: "me",
                                 actionId: PermissionFlow.denyActionIdentifier),
            .resolveOwn(.deny))
    }

    func testRouteForeignDecisionRecordsForOther() {
        // A decision tap for ANOTHER process's notification → hand it off by that id.
        XCTAssertEqual(
            PermissionFlow.route(responseId: "other", myId: "me",
                                 actionId: PermissionFlow.approveActionIdentifier),
            .recordForOther(id: "other", .allow))
    }

    func testRouteOwnBodyClickReveals() {
        XCTAssertEqual(
            PermissionFlow.route(responseId: "me", myId: "me", actionId: "body-or-default"),
            .revealOwn)
    }

    func testRouteForeignBodyClickIgnored() {
        XCTAssertEqual(
            PermissionFlow.route(responseId: "other", myId: "me", actionId: "body-or-default"),
            .ignoreForeignBodyClick)
    }

    func testRouteBeforeOwnIdSetTreatsDecisionAsForeign() {
        // myId is nil until post() assigns it; a decision tap then can't be "ours".
        XCTAssertEqual(
            PermissionFlow.route(responseId: "x", myId: nil,
                                 actionId: PermissionFlow.approveActionIdentifier),
            .recordForOther(id: "x", .allow))
    }
}
