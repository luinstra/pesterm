import Foundation

/// IMPURE, isolated shell around the `tmux` CLI. Every branching/parsing decision is
/// delegated to the pure `TmuxEnv`; this file only locates the binary and runs time-boxed
/// subprocesses. Args are passed as argv (never a shell string), so embedded socket/pane
/// values from the notification userInfo cannot inject a shell command.
enum TmuxClient {

    /// Per-call hard timeout. A wedged tmux server must never block the reveal/run loop.
    static let timeout: TimeInterval = 1.5

    /// How to launch tmux: either an absolute binary, or `/usr/bin/env tmux` as a PATH
    /// fallback (the reveal/responder process may have a minimal env with no useful PATH).
    struct Launcher {
        let exe: String
        let prefixArgs: [String]
    }

    /// Absolute install locations probed in order: Homebrew (Apple Silicon, Intel),
    /// MacPorts, then the system tmux as last resort.
    static let searchPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/opt/local/bin/tmux",
        "/usr/bin/tmux",
    ]

    /// Resolve a launcher, or nil if tmux can't be found (caller falls back to fronting the
    /// app only). Absolute paths first (no subprocess); PATH probe via `env` only if needed.
    static func locateLauncher() -> Launcher? {
        let fm = FileManager.default
        for path in searchPaths where fm.isExecutableFile(atPath: path) {
            return Launcher(exe: path, prefixArgs: [])
        }
        // PATH fallback: verify `env tmux` resolves before committing to it.
        if fm.isExecutableFile(atPath: "/usr/bin/env"),
           let result = run(exe: "/usr/bin/env", args: ["tmux", "-V"], timeout: timeout),
           result.status == 0 {
            return Launcher(exe: "/usr/bin/env", prefixArgs: ["tmux"])
        }
        return nil
    }

    /// The attached (non-control) clients for `pane`'s session. `list-clients -t <pane>`
    /// filters to the session containing the pane; its
    /// `#{client_tty}:#{client_pid}:#{client_control_mode}` rows are parsed by the pure
    /// `TmuxEnv` (pid = the ancestry key for identifying the client's hosting terminal
    /// app). Returns the FULL list (the caller chooses/filters — the remote-attach filter
    /// needs every client, not a pre-collapsed choice). nil when the QUERY itself failed
    /// (launch error / non-zero exit / timeout) — distinct from an empty list (a
    /// successful query, detached) so the caller can tell "query failed" from "detached".
    static func attachedClients(launcher: Launcher, socket: String, pane: String) -> [TmuxEnv.Client]? {
        let args = launcher.prefixArgs + [
            "-S", socket, "list-clients", "-t", pane,
            "-F", "#{client_tty}:#{client_pid}:#{client_control_mode}"
        ]
        guard let result = run(exe: launcher.exe, args: args, timeout: timeout),
              result.status == 0 else {
            return nil
        }
        return TmuxEnv.parseClients(listClientsOutput: result.stdout)
    }

    /// Snap the user onto `pane`: select its window then the pane itself. Best-effort (the
    /// tab is already fronted). Returns false if either select failed (e.g. the pane closed
    /// between query and snap) so the caller can emit a diagnostic.
    @discardableResult
    static func selectPane(launcher: Launcher, socket: String, pane: String) -> Bool {
        let win = run(exe: launcher.exe,
                      args: launcher.prefixArgs + ["-S", socket, "select-window", "-t", pane],
                      timeout: timeout)
        let p = run(exe: launcher.exe,
                    args: launcher.prefixArgs + ["-S", socket, "select-pane", "-t", pane],
                    timeout: timeout)
        return win?.status == 0 && p?.status == 0
    }

    /// Run a process, capturing stdout, with a hard timeout. Returns nil on launch failure
    /// or timeout (the timeout also rescues a pipe-buffer deadlock — we terminate and bail).
    private static func run(exe: String, args: [String], timeout: TimeInterval)
        -> (status: Int32, stdout: String)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            proc.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            // Let the wait thread reap the SIGTERM'd process (don't orphan it / its pipe FD).
            _ = done.wait(timeout: .now() + 0.2)
            return nil
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
