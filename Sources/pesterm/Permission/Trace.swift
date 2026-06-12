import Foundation

/// Lightweight, env-gated tracing for diagnosing the cross-process permission flow.
/// OFF unless `PESTERM_TRACE` names a file path; then appends one line per event:
/// `<unix-ts> pid=<pid> <event>`. Multiple processes append to the same file safely
/// (O_APPEND). This is a DIAGNOSTIC aid — it has no effect in normal use and should be
/// removed (or left dormant) once the permission routing is confirmed.
enum Trace {
    private static let path = ProcessInfo.processInfo.environment["PESTERM_TRACE"]

    static func log(_ event: @autoclosure () -> String) {
        guard let path = path else { return }
        let line = "\(Date().timeIntervalSince1970) pid=\(getpid()) \(event())\n"
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }
}
