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
    ///
    /// Focus-probe note: because `list-clients -t <pane>` scopes to the PANE'S SESSION
    /// (a tmux client is attached to exactly one session), an attached client shown
    /// here is VIEWING that session — the session-level focus dimension is covered by
    /// this existing query; `paneIsActive` adds the window/pane dimension.
    ///
    /// `timeout` defaults to the existing 1.5s (reveal path byte-identical); the focus
    /// probe passes 0.4 for its tighter budget.
    static func attachedClients(launcher: Launcher, socket: String, pane: String,
                                timeout: TimeInterval = TmuxClient.timeout) -> [TmuxEnv.Client]? {
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

    /// Is `pane` the ACTIVE pane of the ACTIVE window of its session? Runs
    /// `tmux -S <socket> display-message -p -t <pane> '#{window_active}#{pane_active}'`
    /// (argv form — never a shell string, same injection discipline as the header
    /// documents) and delegates the parse to the pure `TmuxEnv.parseActiveFlags`
    /// ("11" → true). nil on launch failure / non-zero exit / timeout — the focus
    /// probe treats nil as undetermined → post.
    static func paneIsActive(launcher: Launcher, socket: String, pane: String,
                             timeout: TimeInterval = TmuxClient.timeout) -> Bool? {
        let args = launcher.prefixArgs + [
            "-S", socket, "display-message", "-p", "-t", pane,
            "#{window_active}#{pane_active}"
        ]
        guard let result = run(exe: launcher.exe, args: args, timeout: timeout),
              result.status == 0 else {
            return nil
        }
        return TmuxEnv.parseActiveFlags(result.stdout)
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

    /// Run a process, capturing stdout, with a hard timeout — a thin delegate to the
    /// generalized `Subprocess.run` (the semaphore-timeout pattern was extracted there
    /// for the focus probe; behavior here is byte-identical — tmux children already had
    /// stderr nulled and never read stdin).
    private static func run(exe: String, args: [String], timeout: TimeInterval)
        -> (status: Int32, stdout: String)? {
        return Subprocess.run(exe: exe, args: args, timeout: timeout)
    }
}
