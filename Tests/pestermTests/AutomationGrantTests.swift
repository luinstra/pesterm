import XCTest
@testable import pesterm

/// Pure core of the iTerm Automation (TCC) grant check — the tmux reveal's ScriptingBridge
/// tab-select needs this grant (pesterm is a tmux-daemon descendant there, not iTerm's), and
/// a missing grant used to fail SILENTLY with a misleading "no iTerm tab" diagnostic. The
/// impure AEDeterminePermissionToAutomateTarget call is a thin shell around these.
final class AutomationGrantTests: XCTestCase {

    // MARK: OSStatus → State

    func testNoErrIsGranted() {
        XCTAssertEqual(AutomationGrant.state(forAEResult: 0), .granted)
    }

    func testNotPermittedIsDenied() {
        // errAEEventNotPermitted — the user clicked "Don't Allow" (or a profile denies).
        XCTAssertEqual(AutomationGrant.state(forAEResult: -1743), .denied)
    }

    func testWouldRequireConsentNeedsPrompt() {
        // errAEEventWouldRequireUserConsent — never asked yet (we pass askUserIfNeeded=false).
        XCTAssertEqual(AutomationGrant.state(forAEResult: -1744), .needsPrompt)
    }

    func testProcNotFoundIsUndetermined() {
        // procNotFound — iTerm2 not running; TCC can't be determined without a target.
        guard case .undetermined = AutomationGrant.state(forAEResult: -600) else {
            return XCTFail("procNotFound should be undetermined, not a hard denied/granted")
        }
    }

    func testUnknownStatusIsUndeterminedNeverGranted() {
        // Fail safe: an unrecognized status must never read as granted.
        guard case .undetermined = AutomationGrant.state(forAEResult: -9999) else {
            return XCTFail("unknown status should be undetermined")
        }
    }

    // MARK: describe — actionable, names the Settings pane when action is needed

    func testDescribeDeniedNamesTheSettingsPane() {
        let s = AutomationGrant.describe(.denied)
        XCTAssertTrue(s.contains("Automation"), "denied must point at the Automation pane")
    }

    func testDescribeGrantedIsCalm() {
        XCTAssertEqual(AutomationGrant.describe(.granted), "granted")
    }

    // MARK: the by-tty miss diagnostic — blame the grant only when the grant is the problem

    func testMissDiagnosticWithGrantBlamesTheTab() {
        let s = TmuxRevealer.byTtyMissDiagnostic(tty: "/dev/ttys003", grant: .granted)
        XCTAssertTrue(s.contains("/dev/ttys003"))
        XCTAssertFalse(s.contains("Automation"),
                       "grant is fine — don't send the user to System Settings")
    }

    func testMissDiagnosticWithoutGrantBlamesTheGrant() {
        for grant in [AutomationGrant.State.denied, .needsPrompt] {
            let s = TmuxRevealer.byTtyMissDiagnostic(tty: "/dev/ttys003", grant: grant)
            XCTAssertTrue(s.contains("Automation") || s.contains("automation"),
                          "missing grant must be named — this failure was silent for weeks")
        }
    }
}
