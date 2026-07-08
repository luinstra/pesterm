import XCTest
@testable import pesterm

/// Orchestration tests for the injectable `probeFocus` overloads (the D3 seam):
/// closure-injected readers/deps, NO ScriptingBridge — asserts the Tier0 → read →
/// compare wiring headlessly.
final class FocusProbeSeamTests: XCTestCase {

    private let target = "AAAA-1111-BBBB-2222"
    private let iTermBundle = ITerm2Revealer.iTermBundleID

    private func makeRevealer() -> ITerm2Revealer {
        return ITerm2Revealer(targetSessionId: target)
    }

    // MARK: - iTerm2 (Phase 1)

    func testITermSupportsBothKinds() {
        let r = makeRevealer()
        XCTAssertTrue(r.supportsFocusSuppression(for: .permission))
        XCTAssertTrue(r.supportsFocusSuppression(for: .info))
    }

    func testITermTier0MissShortCircuits() {
        let r = makeRevealer()
        var readerCalled = false
        let verdict = r.probeFocus(frontmostBundleID: "com.apple.Safari") { _, _ in
            readerCalled = true
            return self.target
        }
        XCTAssertEqual(verdict, .unverified("iTerm2 not frontmost"))
        XCTAssertFalse(readerCalled, "Tier-0 miss must never spawn the probe child")
    }

    func testITermTier0NilFrontmostShortCircuits() {
        let r = makeRevealer()
        var readerCalled = false
        let verdict = r.probeFocus(frontmostBundleID: nil) { _, _ in
            readerCalled = true
            return self.target
        }
        XCTAssertEqual(verdict, .unverified("iTerm2 not frontmost"))
        XCTAssertFalse(readerCalled)
    }

    func testITermReaderNilIsUnverified() {
        let r = makeRevealer()
        let verdict = r.probeFocus(frontmostBundleID: iTermBundle) { variant, timeout in
            XCTAssertEqual(variant, "iterm-session-id")
            XCTAssertEqual(timeout, 0.5, accuracy: 0.001)
            return nil
        }
        XCTAssertEqual(verdict, .unverified("probe timeout/empty"))
    }

    func testITermReaderTargetGuidIsFocused() {
        let r = makeRevealer()
        let verdict = r.probeFocus(frontmostBundleID: iTermBundle) { _, _ in self.target }
        XCTAssertEqual(verdict, .focused)
    }

    func testITermReaderOtherGuidIsUnverified() {
        let r = makeRevealer()
        let verdict = r.probeFocus(frontmostBundleID: iTermBundle) { _, _ in "OTHER-GUID" }
        XCTAssertEqual(verdict, .unverified("another session is focused"))
    }

    // MARK: - tmux (Phase 2)

    private let launcher = TmuxClient.Launcher(exe: "/usr/bin/true", prefixArgs: [])
    private let client = TmuxEnv.Client(tty: "/dev/ttys003", pid: 100)

    /// Deps whose every edge FAILS the test if reached — individual tests override
    /// only the steps they expect to run, so an unexpected extra call is loud.
    private func trippingDeps() -> TmuxRevealer.FocusProbeDeps {
        var deps = TmuxRevealer.FocusProbeDeps()
        deps.grantCheck = { XCTFail("grantCheck must not be called"); return .denied }
        deps.locateLauncher = { XCTFail("locateLauncher must not be called"); return nil }
        deps.attachedClients = { _, _, _, _ in
            XCTFail("attachedClients must not be called"); return nil
        }
        deps.resolveClients = { _ in
            XCTFail("resolveClients must not be called"); return .detached
        }
        deps.paneIsActive = { _, _, _, _ in
            XCTFail("paneIsActive must not be called"); return nil
        }
        deps.readValue = { _, _ in XCTFail("readValue must not be called"); return nil }
        return deps
    }

    private func makeTmuxRevealer() -> TmuxRevealer {
        return TmuxRevealer(socket: "/private/tmp/tmux-501/default", pane: "%5")
    }

    func testTmuxSupportsBothKinds() {
        let r = makeTmuxRevealer()
        XCTAssertTrue(r.supportsFocusSuppression(for: .permission))
        XCTAssertTrue(r.supportsFocusSuppression(for: .info))
    }

    func testTmuxTier0MissShortCircuitsEverything() {
        let r = makeTmuxRevealer()
        // Ghostty frontmost: tmux probe is iTerm-only — nothing else may run.
        let verdict = r.probeFocus(frontmostBundleID: "com.mitchellh.ghostty",
                                   deps: trippingDeps())
        XCTAssertEqual(verdict, .unverified("iTerm2 not frontmost (tmux focus probe is iTerm-only)"))
    }

    func testTmuxNonGrantedMakesNoClientCall() {
        let r = makeTmuxRevealer()
        for state in [AutomationGrant.State.denied, .needsPrompt, .undetermined("x")] {
            var deps = trippingDeps()
            deps.grantCheck = { state }
            let verdict = r.probeFocus(frontmostBundleID: iTermBundle, deps: deps)
            XCTAssertEqual(verdict, .unverified("iTerm automation grant not granted"),
                           "grant \(state) must be unverified, probe child never spawned")
        }
    }

    func testTmuxRemoteOnlyResolutionIsUnverified() {
        // The SAME input that yields the remoteOnly diagnostic on the reveal path
        // yields .unverified on the probe path.
        let r = makeTmuxRevealer()
        var deps = trippingDeps()
        deps.grantCheck = { .granted }
        deps.locateLauncher = { self.launcher }
        deps.attachedClients = { _, _, _, _ in [self.client] }
        deps.resolveClients = { _ in .remoteOnly }
        let verdict = r.probeFocus(frontmostBundleID: iTermBundle, deps: deps)
        XCTAssertEqual(verdict, .unverified("attached clients are remote-only"))
    }

    func testTmuxMultipleAndDetachedResolutionsAreUnverified() {
        let r = makeTmuxRevealer()
        for (resolution, reason) in [(TmuxEnv.ClientResolution.multiple,
                                      "multiple locally-hosted clients"),
                                     (.detached, "no attached tmux client")] {
            var deps = trippingDeps()
            deps.grantCheck = { .granted }
            deps.locateLauncher = { self.launcher }
            deps.attachedClients = { _, _, _, _ in [] }
            deps.resolveClients = { _ in resolution }
            XCTAssertEqual(r.probeFocus(frontmostBundleID: iTermBundle, deps: deps),
                           .unverified(reason))
        }
    }

    func testTmuxQueryFailedIsUnverified() {
        let r = makeTmuxRevealer()
        var deps = trippingDeps()
        deps.grantCheck = { .granted }
        deps.locateLauncher = { self.launcher }
        deps.attachedClients = { _, _, _, _ in nil }
        XCTAssertEqual(r.probeFocus(frontmostBundleID: iTermBundle, deps: deps),
                       .unverified("tmux client query failed"))
    }

    func testTmuxPaneInactiveIsUnverified() {
        let r = makeTmuxRevealer()
        var deps = trippingDeps()
        deps.grantCheck = { .granted }
        deps.locateLauncher = { self.launcher }
        deps.attachedClients = { _, _, _, _ in [self.client] }
        deps.resolveClients = { _ in .one(self.client) }
        deps.paneIsActive = { _, _, _, _ in false }
        XCTAssertEqual(r.probeFocus(frontmostBundleID: iTermBundle, deps: deps),
                       .unverified("target pane not active"))
    }

    func testTmuxPaneQueryNilIsUnverified() {
        let r = makeTmuxRevealer()
        var deps = trippingDeps()
        deps.grantCheck = { .granted }
        deps.locateLauncher = { self.launcher }
        deps.attachedClients = { _, _, _, _ in [self.client] }
        deps.resolveClients = { _ in .one(self.client) }
        deps.paneIsActive = { _, _, _, _ in nil }
        XCTAssertEqual(r.probeFocus(frontmostBundleID: iTermBundle, deps: deps),
                       .unverified("target pane not active"))
    }

    func testTmuxTtyMismatchIsUnverified() {
        let r = makeTmuxRevealer()
        var deps = trippingDeps()
        deps.grantCheck = { .granted }
        deps.locateLauncher = { self.launcher }
        deps.attachedClients = { _, _, _, _ in [self.client] }
        deps.resolveClients = { _ in .one(self.client) }
        deps.paneIsActive = { _, _, _, _ in true }
        deps.readValue = { variant, timeout in
            XCTAssertEqual(variant, "iterm-session-tty")
            XCTAssertEqual(timeout, 0.5, accuracy: 0.001)
            return "/dev/ttys999"
        }
        XCTAssertEqual(r.probeFocus(frontmostBundleID: iTermBundle, deps: deps),
                       .unverified("iTerm is fronting a different session"))
    }

    // MARK: - Ghostty (Phase 3, info-path only)

    func testGhosttyPermissionNeverProbes() {
        // Permission suppression is deliberately withheld in Ghostty (same-cwd
        // surfaces are indistinguishable — a wrong suppress would strand the
        // approval). The kind gate is what keeps the probe from ever running:
        // main.swift only probes when supportsFocusSuppression(for:) is true.
        let r = GhosttyRevealer(cwd: "/Users/me/proj")
        XCTAssertFalse(r.supportsFocusSuppression(for: .permission))
        XCTAssertTrue(r.supportsFocusSuppression(for: .info))
    }

    func testGhosttyTier0MissShortCircuits() {
        let r = GhosttyRevealer(cwd: "/Users/me/proj")
        var readerCalled = false
        let verdict = r.probeFocus(frontmostBundleID: iTermBundle) { _, _ in
            readerCalled = true
            return "/Users/me/proj"
        }
        XCTAssertEqual(verdict, .unverified("Ghostty not frontmost"))
        XCTAssertFalse(readerCalled)
    }

    func testGhosttyAppOnlyTargetNeverFocused() {
        // No captured cwd → app-only tier can never be a hard YES.
        let r = GhosttyRevealer(cwd: nil)
        var readerCalled = false
        let verdict = r.probeFocus(frontmostBundleID: GhosttyRevealer.ghosttyBundleID) { _, _ in
            readerCalled = true
            return "/anything"
        }
        XCTAssertEqual(verdict, .unverified("no cwd captured (app-only target)"))
        XCTAssertFalse(readerCalled)
    }

    func testGhosttyReaderNilIsUnverified() {
        let r = GhosttyRevealer(cwd: "/Users/me/proj")
        let verdict = r.probeFocus(frontmostBundleID: GhosttyRevealer.ghosttyBundleID) { variant, timeout in
            XCTAssertEqual(variant, "ghostty-cwd")
            XCTAssertEqual(timeout, 0.5, accuracy: 0.001)
            return nil
        }
        XCTAssertEqual(verdict, .unverified("probe timeout/empty"))
    }

    func testGhosttyMatchingCwdIsFocused() {
        let r = GhosttyRevealer(cwd: "/Users/me/proj")
        let verdict = r.probeFocus(frontmostBundleID: GhosttyRevealer.ghosttyBundleID) { _, _ in
            "/Users/me/proj"
        }
        XCTAssertEqual(verdict, .focused)
    }

    func testGhosttyMismatchedCwdIsUnverified() {
        let r = GhosttyRevealer(cwd: "/Users/me/proj")
        let verdict = r.probeFocus(frontmostBundleID: GhosttyRevealer.ghosttyBundleID) { _, _ in
            "/Users/me/elsewhere"
        }
        XCTAssertEqual(verdict, .unverified("focused surface is in a different directory"))
    }

    func testTmuxFullHappyPathIsFocused() {
        let r = makeTmuxRevealer()
        var deps = trippingDeps()
        deps.grantCheck = { .granted }
        deps.locateLauncher = { self.launcher }
        deps.attachedClients = { launcher, socket, pane, timeout in
            XCTAssertEqual(socket, "/private/tmp/tmux-501/default")
            XCTAssertEqual(pane, "%5")
            XCTAssertEqual(timeout, 0.4, accuracy: 0.001, "probe budget, not the 1.5s reveal default")
            return [self.client]
        }
        deps.resolveClients = { _ in .one(self.client) }
        deps.paneIsActive = { _, _, pane, timeout in
            XCTAssertEqual(pane, "%5")
            XCTAssertEqual(timeout, 0.4, accuracy: 0.001)
            return true
        }
        // Trailing newline: normalizeTTY on both sides.
        deps.readValue = { _, _ in "/dev/ttys003\n" }
        XCTAssertEqual(r.probeFocus(frontmostBundleID: iTermBundle, deps: deps), .focused)
    }
}
