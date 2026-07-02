import XCTest
@testable import pesterm

/// Pure core of the Automation (TCC) grant check — needed by the tmux reveal path
/// (pesterm is a tmux-daemon descendant there, not iTerm's) and the Ghostty
/// relaunch-responder click path (LaunchServices-launched pesterm is no Ghostty
/// descendant). A missing grant used to fail SILENTLY with a misleading "no tab"
/// diagnostic. The impure AEDeterminePermissionToAutomateTarget call is a thin shell
/// around these. Every helper takes the app name explicitly — a defaulted parameter
/// would silently reintroduce the wrong-app string.
final class AutomationGrantTests: XCTestCase {

    // MARK: OSStatus → State

    func testNoErrIsGranted() {
        XCTAssertEqual(AutomationGrant.state(forAEResult: 0, appName: "iTerm2"), .granted)
        XCTAssertEqual(AutomationGrant.state(forAEResult: 0, appName: "Ghostty"), .granted)
    }

    func testNotPermittedIsDenied() {
        // errAEEventNotPermitted — the user clicked "Don't Allow" (or a profile denies).
        XCTAssertEqual(AutomationGrant.state(forAEResult: -1743, appName: "iTerm2"), .denied)
        XCTAssertEqual(AutomationGrant.state(forAEResult: -1743, appName: "Ghostty"), .denied)
    }

    func testWouldRequireConsentNeedsPrompt() {
        // errAEEventWouldRequireUserConsent — never asked yet (we pass askUserIfNeeded=false).
        XCTAssertEqual(AutomationGrant.state(forAEResult: -1744, appName: "iTerm2"), .needsPrompt)
        XCTAssertEqual(AutomationGrant.state(forAEResult: -1744, appName: "Ghostty"), .needsPrompt)
    }

    func testProcNotFoundIsUndeterminedWithAppSpecificMessage() {
        // procNotFound — the target app isn't running; TCC can't be determined without a
        // target. The message must name THE app checked (a hardcoded "iTerm2 not
        // running" would misreport for Ghostty).
        XCTAssertEqual(AutomationGrant.state(forAEResult: -600, appName: "iTerm2"),
                       .undetermined("iTerm2 not running"))
        XCTAssertEqual(AutomationGrant.state(forAEResult: -600, appName: "Ghostty"),
                       .undetermined("Ghostty not running"))
    }

    func testUnknownStatusIsUndeterminedNeverGranted() {
        // Fail safe: an unrecognized status must never read as granted.
        for appName in ["iTerm2", "Ghostty"] {
            guard case .undetermined = AutomationGrant.state(forAEResult: -9999,
                                                             appName: appName) else {
                return XCTFail("unknown status should be undetermined for \(appName)")
            }
        }
    }

    // MARK: describe — actionable, names the app and the Settings pane when action is needed

    func testDescribeDeniedNamesTheAppAndSettingsPane() {
        let iterm = AutomationGrant.describe(.denied, appName: "iTerm2")
        XCTAssertTrue(iterm.contains("Automation"), "denied must point at the Automation pane")
        XCTAssertTrue(iterm.contains("pesterm → iTerm2"), "denied must name the app row to enable")

        let ghostty = AutomationGrant.describe(.denied, appName: "Ghostty")
        XCTAssertTrue(ghostty.contains("Automation"))
        XCTAssertTrue(ghostty.contains("pesterm → Ghostty"))
    }

    func testDescribeNeedsPromptNamesTheApp() {
        let s = AutomationGrant.describe(.needsPrompt, appName: "Ghostty")
        XCTAssertTrue(s.contains("Ghostty"), "needsPrompt must name the app's reveal context")
    }

    func testDescribeGrantedIsCalm() {
        XCTAssertEqual(AutomationGrant.describe(.granted, appName: "iTerm2"), "granted")
        XCTAssertEqual(AutomationGrant.describe(.granted, appName: "Ghostty"), "granted")
    }

    // MARK: statusLine — the pure seam behind `pesterm status`'s installed-app gating

    func testStatusLineNilWhenAppNotInstalled() {
        XCTAssertNil(AutomationGrant.statusLine(appName: "Ghostty", installed: false,
                                                state: .granted),
                     "no Ghostty installed → no Ghostty noise in status")
    }

    func testStatusLineNamesAppAndState() {
        let line = AutomationGrant.statusLine(appName: "Ghostty", installed: true,
                                              state: .granted)
        XCTAssertEqual(line, "Ghostty automation (needed for the jump-to-tab reveal): granted")
    }
}
