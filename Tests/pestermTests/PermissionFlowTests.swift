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

    func testRouteForeignBodyClickRevealsForeign() {
        // A body click for another process's notification still deserves its reveal —
        // the OS delivered the tap HERE; the owner will never see it. For an info
        // notification reveal-on-click is its entire purpose.
        XCTAssertEqual(
            PermissionFlow.route(responseId: "other", myId: "me", actionId: "body-or-default"),
            .revealForeign)
    }

    func testRouteBeforeOwnIdSetTreatsDecisionAsForeign() {
        // myId is nil until post() assigns it; a decision tap then can't be "ours".
        XCTAssertEqual(
            PermissionFlow.route(responseId: "x", myId: nil,
                                 actionId: PermissionFlow.approveActionIdentifier),
            .recordForOther(id: "x", .allow))
    }

    // MARK: responseAction — what THIS process does with a routed tap, by kind.
    // macOS hands each tap to ONE delegate per bundle id, so an info process can receive
    // a permission tap (and vice versa). The action must not depend on swallowing it.

    func testPermissionResolveOwn() {
        XCTAssertEqual(
            PermissionFlow.responseAction(kind: .permission, routing: .resolveOwn(.allow)),
            .resolveOwn(.allow))
    }

    func testPermissionRecordsForOther() {
        XCTAssertEqual(
            PermissionFlow.responseAction(kind: .permission,
                                          routing: .recordForOther(id: "other", .deny)),
            .recordForOther(id: "other", .deny))
    }

    func testPermissionOwnBodyClickKeepsWaiting() {
        XCTAssertEqual(
            PermissionFlow.responseAction(kind: .permission, routing: .revealOwn),
            .revealOwnKeepWaiting)
    }

    func testInfoOwnBodyClickRevealsThenExits() {
        // The classic info path: reveal, then exit.
        XCTAssertEqual(
            PermissionFlow.responseAction(kind: .info, routing: .revealOwn),
            .revealOwnThenExit)
    }

    func testInfoRecordsForeignDecisionInsteadOfSwallowingIt() {
        // THE bug: a live info process that receives another process's Approve must hand
        // it off via the store — treating it as its own activation loses the approval.
        XCTAssertEqual(
            PermissionFlow.responseAction(kind: .info,
                                          routing: .recordForOther(id: "other", .allow)),
            .recordForOther(id: "other", .allow))
    }

    func testForeignBodyClickRevealsForeignForBothKinds() {
        XCTAssertEqual(
            PermissionFlow.responseAction(kind: .info, routing: .revealForeign),
            .revealForeign)
        XCTAssertEqual(
            PermissionFlow.responseAction(kind: .permission, routing: .revealForeign),
            .revealForeign)
    }

    func testInfoResolveOwnIsDefensivelyRevealThenExit() {
        // Unreachable in practice (info notifications carry no Approve/Deny category),
        // but if it ever happened the safe move is the old info behavior.
        XCTAssertEqual(
            PermissionFlow.responseAction(kind: .info, routing: .resolveOwn(.allow)),
            .revealOwnThenExit)
    }

    // MARK: dismissal grace — the card vanished, but the decision may still be in flight
    // (tap handled by a freshly relaunched responder that hasn't written the store yet).

    func testDismissalWithStoredDecisionResolves() {
        XCTAssertEqual(
            PermissionFlow.dismissalAction(storeDecision: .allow, graceElapsed: false),
            .resolve(.allow))
        XCTAssertEqual(
            PermissionFlow.dismissalAction(storeDecision: .deny, graceElapsed: true),
            .resolve(.deny))
    }

    func testDismissalWithoutDecisionStartsGraceFirst() {
        XCTAssertEqual(
            PermissionFlow.dismissalAction(storeDecision: nil, graceElapsed: false),
            .startGrace)
    }

    func testDismissalAfterGraceFinalizes() {
        XCTAssertEqual(
            PermissionFlow.dismissalAction(storeDecision: nil, graceElapsed: true),
            .finalizeDismissed)
    }

    func testDismissGraceIsShortButNonZero() {
        // Long enough for a cold responder relaunch to write the store; short enough
        // that a real dismissal still falls back to the terminal promptly.
        XCTAssertGreaterThanOrEqual(PermissionFlow.dismissGraceSeconds, 2)
        XCTAssertLessThanOrEqual(PermissionFlow.dismissGraceSeconds, 10)
    }
}
