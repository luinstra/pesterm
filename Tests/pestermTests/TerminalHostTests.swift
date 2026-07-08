import XCTest
@testable import pesterm

/// Pure cores of the tmux tier-2 reveal: carrying the client PID alongside its tty
/// (list-clients parse), and classifying a client's process-ancestry executable paths
/// into the terminal app hosting it. The host is EVIDENCE for fronting — with two
/// terminals open, a tmux client can be attached from either, and fronting the wrong
/// one is the bug class D5 eliminated. Ancestry answers "which app" without guessing;
/// the impure ppid walk (ProcessAncestry) is the thin shell around this.
final class TerminalHostTests: XCTestCase {

    // MARK: TmuxEnv.parseClients — format `#{client_tty}:#{client_pid}:#{client_control_mode}`

    func testParseClientsHappyPath() {
        let clients = TmuxEnv.parseClients(listClientsOutput: "/dev/ttys003:12345:0\n")
        XCTAssertEqual(clients, [TmuxEnv.Client(tty: "/dev/ttys003", pid: 12345)])
    }

    func testParseClientsSkipsControlMode() {
        // An IDE/control client must never become the reveal target.
        let clients = TmuxEnv.parseClients(
            listClientsOutput: "/dev/ttys003:12345:0\n/dev/ttys009:999:1\n")
        XCTAssertEqual(clients, [TmuxEnv.Client(tty: "/dev/ttys003", pid: 12345)])
    }

    func testParseClientsGarbagePidDegradesToNilPidNotDroppedClient() {
        // A client we can't pid is still a REAL attached client — the tty (and the
        // one-vs-many decision) must survive; only the ancestry upgrade is lost.
        let clients = TmuxEnv.parseClients(listClientsOutput: "/dev/ttys003:notanumber:0\n")
        XCTAssertEqual(clients, [TmuxEnv.Client(tty: "/dev/ttys003", pid: nil)])
    }

    func testParseClientsWhitespaceAndEmptyLines() {
        let clients = TmuxEnv.parseClients(listClientsOutput: "\n  /dev/ttys017:42:0  \n\n")
        XCTAssertEqual(clients, [TmuxEnv.Client(tty: "/dev/ttys017", pid: 42)])
    }

    // MARK: resolveClients — one/detached/multiple/remoteOnly in ONE rule
    // (replaced the chooseClient/chooseLocalClient pair in the focus-probe extraction)

    func testResolveClientsCountSemantics() {
        let a = TmuxEnv.Client(tty: "/dev/ttys003", pid: 1)
        let b = TmuxEnv.Client(tty: "/dev/ttys005", pid: 2)
        XCTAssertEqual(TmuxEnv.resolveClients([]), .detached)
        // Exactly 1 → .one WITHOUT local filtering (matches the old inline reveal(),
        // which only filtered on the multiple case).
        XCTAssertEqual(TmuxEnv.resolveClients([(a, false)]), .one(a))
        XCTAssertEqual(TmuxEnv.resolveClients([(a, true), (b, true)]), .multiple)
    }

    // MARK: TerminalHost.classify — ancestry executable paths → hosting terminal app

    func testClassifyITermAncestry() {
        let host = TerminalHost.classify(executablePaths: [
            "/usr/local/bin/tmux",
            "/Applications/iTerm.app/Contents/MacOS/iTerm2",
        ])
        XCTAssertEqual(host?.bundleID, ITerm2Revealer.iTermBundleID)
        XCTAssertEqual(host?.appName, "iTerm2")
    }

    func testClassifyGhosttyAncestry() {
        let host = TerminalHost.classify(executablePaths: [
            "/bin/zsh",
            "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            "/sbin/launchd",
        ])
        XCTAssertEqual(host?.bundleID, GhosttyRevealer.ghosttyBundleID)
        XCTAssertEqual(host?.appName, "Ghostty")
    }

    func testClassifyNearestAncestorWins() {
        // Paths are ordered child → parent; the NEAREST terminal ancestor is the host
        // (a terminal launched from another terminal belongs to the inner one).
        let host = TerminalHost.classify(executablePaths: [
            "/Applications/Ghostty.app/Contents/MacOS/ghostty",
            "/Applications/iTerm.app/Contents/MacOS/iTerm2",
        ])
        XCTAssertEqual(host?.appName, "Ghostty")
    }

    // MARK: resolveClients — remote attaches (mosh/ssh) are NOT reveal candidates

    func testMoshPlusLocalReducesToTheLocalClient() {
        // THE real-world case: a forgotten mosh attach shares the session with the real
        // iTerm tab. The mosh client cannot be revealed locally — dropping it is pure
        // logic, not preference — so the local client proceeds with full precision.
        let iterm = TmuxEnv.Client(tty: "/dev/ttys008", pid: 100)
        let mosh = TmuxEnv.Client(tty: "/dev/ttys014", pid: 200)
        XCTAssertEqual(
            TmuxEnv.resolveClients([(iterm, true), (mosh, false)]),
            .one(iterm))
    }

    func testTwoLocalClientsStayAmbiguous() {
        // Two LOCAL displays is genuine ambiguity — still never guess.
        let a = TmuxEnv.Client(tty: "/dev/ttys001", pid: 1)
        let b = TmuxEnv.Client(tty: "/dev/ttys002", pid: 2)
        XCTAssertEqual(TmuxEnv.resolveClients([(a, true), (b, true)]), .multiple)
    }

    func testAllRemoteMultiClientIsRemoteOnly() {
        // Session attached ONLY via mosh/ssh (2+ clients) → nothing local to reveal;
        // .remoteOnly is first-class so the diagnostic names the invisible culprit.
        let moshA = TmuxEnv.Client(tty: "/dev/ttys014", pid: 200)
        let moshB = TmuxEnv.Client(tty: "/dev/ttys015", pid: 201)
        XCTAssertEqual(TmuxEnv.resolveClients([(moshA, false), (moshB, false)]), .remoteOnly)
    }

    func testClassifyUnknownOrEmptyIsNil() {
        // Unknown host → nil → the caller fronts NOTHING (never guess). Terminal.app is
        // deliberately unclassified until pesterm has a revealer story for it.
        XCTAssertNil(TerminalHost.classify(executablePaths: ["/bin/bash", "/sbin/launchd"]))
        XCTAssertNil(TerminalHost.classify(executablePaths: [
            "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]))
        XCTAssertNil(TerminalHost.classify(executablePaths: []))
    }
}
