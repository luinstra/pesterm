import XCTest
@testable import pesterm

final class FocusPolicyTests: XCTestCase {

    // MARK: - Tier 0: hostIsFrontmost

    func testHostIsFrontmostMatch() {
        XCTAssertTrue(FocusPolicy.hostIsFrontmost(expectedBundleID: "com.googlecode.iterm2",
                                                  frontmostBundleID: "com.googlecode.iterm2"))
    }

    func testHostIsFrontmostMismatch() {
        XCTAssertFalse(FocusPolicy.hostIsFrontmost(expectedBundleID: "com.googlecode.iterm2",
                                                   frontmostBundleID: "com.apple.Safari"))
    }

    func testHostIsFrontmostNilFrontmost() {
        XCTAssertFalse(FocusPolicy.hostIsFrontmost(expectedBundleID: "com.googlecode.iterm2",
                                                   frontmostBundleID: nil))
    }

    func testHostIsFrontmostNilExpected() {
        XCTAssertFalse(FocusPolicy.hostIsFrontmost(expectedBundleID: nil,
                                                   frontmostBundleID: "com.googlecode.iterm2"))
    }

    func testHostIsFrontmostEmptyStringsNeverMatch() {
        XCTAssertFalse(FocusPolicy.hostIsFrontmost(expectedBundleID: "",
                                                   frontmostBundleID: ""))
    }

    // MARK: - action: suppress ONLY on (.focused AND probeSupportsKind), both kinds

    func testActionSuppressesOnFocusedAndSupportedPermission() {
        let action = FocusPolicy.action(kind: .permission, verdict: .focused,
                                        probeSupportsKind: true, resolvedSound: "Glass")
        guard case .suppress(let sound, let diagnostic) = action else {
            return XCTFail("expected .suppress, got \(action)")
        }
        XCTAssertEqual(sound, "Glass")
        XCTAssertTrue(diagnostic.contains("permission prompt falls back"))
    }

    func testActionSuppressesOnFocusedAndSupportedInfo() {
        let action = FocusPolicy.action(kind: .info, verdict: .focused,
                                        probeSupportsKind: true, resolvedSound: "Pop")
        guard case .suppress(let sound, let diagnostic) = action else {
            return XCTFail("expected .suppress, got \(action)")
        }
        XCTAssertEqual(sound, "Pop")
        XCTAssertTrue(diagnostic.contains("notification suppressed"))
    }

    func testActionPostsOnFocusedButUnsupported() {
        XCTAssertEqual(FocusPolicy.action(kind: .permission, verdict: .focused,
                                          probeSupportsKind: false, resolvedSound: "Glass"),
                       .post)
        XCTAssertEqual(FocusPolicy.action(kind: .info, verdict: .focused,
                                          probeSupportsKind: false, resolvedSound: "Glass"),
                       .post)
    }

    func testActionPostsOnUnverifiedEvenWhenSupported() {
        XCTAssertEqual(FocusPolicy.action(kind: .permission, verdict: .unverified("x"),
                                          probeSupportsKind: true, resolvedSound: "Glass"),
                       .post)
        XCTAssertEqual(FocusPolicy.action(kind: .info, verdict: .unverified("x"),
                                          probeSupportsKind: true, resolvedSound: "Glass"),
                       .post)
    }

    func testActionPostsOnUnverifiedAndUnsupported() {
        XCTAssertEqual(FocusPolicy.action(kind: .permission, verdict: .unverified("x"),
                                          probeSupportsKind: false, resolvedSound: nil),
                       .post)
        XCTAssertEqual(FocusPolicy.action(kind: .info, verdict: .unverified("x"),
                                          probeSupportsKind: false, resolvedSound: nil),
                       .post)
    }

    // EVERY .unverified(reason) — regardless of reason content — maps to the BARE .post
    // (D3: reasons are observability, Trace-logged at the probe layer; FocusAction
    // never carries them).
    func testActionIgnoresUnverifiedReasonContent() {
        let reasons = ["", "probe timeout/empty", "another session is focused",
                       "iTerm2 not frontmost", "no focus probe for this terminal",
                       "grant=denied", String(repeating: "x", count: 10_000)]
        for reason in reasons {
            for kind in [NotificationKind.permission, .info] {
                XCTAssertEqual(FocusPolicy.action(kind: kind, verdict: .unverified(reason),
                                                  probeSupportsKind: true,
                                                  resolvedSound: "Glass"),
                               .post, "reason \(reason.prefix(30)) must map to bare .post")
            }
        }
    }

    // MARK: - sound pass-through

    func testActionPassesNilSoundThroughOnSuppress() {
        // --sound none silenced the request: suppression stays silent too.
        let action = FocusPolicy.action(kind: .info, verdict: .focused,
                                        probeSupportsKind: true, resolvedSound: nil)
        guard case .suppress(let sound, _) = action else {
            return XCTFail("expected .suppress, got \(action)")
        }
        XCTAssertNil(sound)
    }

    // MARK: - diagnostics per kind

    func testDiagnosticTextPerKind() {
        XCTAssertEqual(FocusPolicy.diagnostic(for: .permission),
                       "pesterm: terminal focused — permission prompt falls back to "
                       + "Claude's terminal UI; nothing posted")
        XCTAssertEqual(FocusPolicy.diagnostic(for: .info),
                       "pesterm: terminal focused — notification suppressed; nothing posted")
    }

    // MARK: - protocol defaults never suppress (task 3)

    /// A conformance that does NOT opt in to focus probing (uses the protocol
    /// extension defaults) can never yield a suppress — fail-toward-posting by
    /// construction.
    func testDefaultProbeVerdictNeverSuppresses() {
        final class NoOpRevealer: TerminalRevealer {
            static func detect(_ env: [String: String]) -> TerminalRevealer? { nil }
            var capability: RevealCapability { .appOnly }
            func reveal() throws {}
            var revealUserInfo: [String: String] { [:] }
            static func reveal(from userInfo: [String: String]) -> TerminalRevealer? { nil }
        }
        let revealer = NoOpRevealer()
        for kind in [NotificationKind.permission, .info] {
            let supported = revealer.supportsFocusSuppression(for: kind)
            XCTAssertFalse(supported)
            let verdict = revealer.probeFocus(frontmostBundleID: "com.googlecode.iterm2")
            XCTAssertEqual(verdict, .unverified("no focus probe for this terminal"))
            XCTAssertEqual(FocusPolicy.action(kind: kind, verdict: verdict,
                                              probeSupportsKind: supported,
                                              resolvedSound: "Glass"),
                           .post)
        }
    }
}
