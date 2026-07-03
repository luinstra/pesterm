import Foundation

/// Lightweight, gated tracing for diagnosing the cross-process notification flow.
/// Appends one line per event: `<unix-ts> pid=<pid> <event>`. Multiple processes append
/// to the same file safely (O_APPEND).
///
/// Resolution order (env wins; the marker is the fallback for processes that don't
/// inherit a curated env):
///   1. `PESTERM_TRACE=<path>`     → that path
///   2. `~/.pesterm-debug` exists  → `~/.pesterm-debug.log`  (marker gate)
///   3. otherwise                  → nil (tracing off; zero cost)
///
/// The MARKER gate is load-bearing for field diagnosis, not a temporary aid: the
/// processes that matter most — hook subprocesses spawned by an agent, and above all
/// the relaunch responder that LaunchServices spawns to deliver a tap after the poster
/// exited — inherit NO curated env, so `PESTERM_TRACE` can never reach them. `touch
/// ~/.pesterm-debug` turns tracing on for every pesterm process on the machine (they
/// all see `$HOME`); `rm ~/.pesterm-debug` turns it off. Gate off ⇒ genuine no-op.
enum Trace {
    /// See the resolution order in the type doc. Computed once per process: env path
    /// wins; else the `~/.pesterm-debug` marker enables `~/.pesterm-debug.log`; else nil
    /// (off). `$HOME` is read from the env (the reliable signal for a spawned
    /// subprocess), NOT `homeDirectoryForCurrentUser`.
    private static let path: String? = resolvePath(
        env: ProcessInfo.processInfo.environment,
        markerExists: { FileManager.default.fileExists(atPath: $0) }
    )

    /// PURE, testable resolver for the trace path (no I/O of its own — `markerExists` is
    /// injected). Implements the resolution order: a non-empty `PESTERM_TRACE` wins; else if
    /// `HOME` is set AND `<HOME>/.pesterm-debug` exists → `<HOME>/.pesterm-debug.log`; else nil.
    static func resolvePath(env: [String: String], markerExists: (String) -> Bool) -> String? {
        if let p = env["PESTERM_TRACE"], !p.isEmpty { return p }
        guard let home = env["HOME"], !home.isEmpty else { return nil }
        guard markerExists(home + "/.pesterm-debug") else { return nil }
        return home + "/.pesterm-debug.log"
    }

    /// Cheap gate check: is tracing on? Callers wrap a diagnostic block in `if Trace.isEnabled`
    /// so any (pure but non-free) decode+render only runs when a trace will actually be written.
    static var isEnabled: Bool { path != nil }

    static func log(_ event: @autoclosure () -> String) {
        guard let path = path else { return }
        let line = "\(Date().timeIntervalSince1970) pid=\(getpid()) \(event())\n"
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }
}
