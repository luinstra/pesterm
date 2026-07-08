import Foundation

/// IMPURE, generic time-boxed subprocess runner — the semaphore-wait + `terminate()`
/// pattern extracted from `TmuxClient.run` (behavior byte-identical; `TmuxClient` now
/// delegates here). Used by both the tmux CLI calls and the focus-probe child.
///
/// FD discipline (load-bearing on the permission path, where the hook's stdout is
/// Claude's decision channel): children get `standardInput` and `standardError` set to
/// `FileHandle.nullDevice` — stdout is the ONLY captured channel, and the child can
/// never hold or write into the parent's stdio.
enum Subprocess {

    /// Run `exe args...`, capturing stdout, with a hard timeout. Returns nil on launch
    /// failure or timeout (the timeout also rescues a pipe-buffer deadlock — we
    /// terminate and bail). A wedged child is SIGTERMed at the deadline and briefly
    /// reaped so neither it nor its pipe FD is orphaned.
    static func run(exe: String, args: [String], timeout: TimeInterval)
        -> (status: Int32, stdout: String)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
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
