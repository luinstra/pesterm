import Foundation
import Darwin

/// IMPURE, isolated shell around the kernel's process table: walk a pid's parent chain
/// and collect each ancestor's executable path. All classification happens in the pure
/// `TerminalHost` — this file only reads `proc_pidpath` and `kinfo_proc.ppid`.
///
/// Bounded and best-effort: a dead pid, permission failure, or cycle simply ends the
/// walk (the caller degrades to front-nothing). No subprocesses — direct syscalls only.
enum ProcessAncestry {

    /// Executable paths from `pid` upward (child → parent), stopping at launchd (pid 1),
    /// pid 0, a lookup failure, or `maxDepth` (runaway/cycle guard).
    static func executablePaths(startingAt pid: Int32, maxDepth: Int = 24) -> [String] {
        var paths: [String] = []
        var current = pid
        var depth = 0
        while current > 1 && depth < maxDepth {
            if let path = executablePath(of: current), !path.isEmpty {
                paths.append(path)
            }
            guard let parent = parentPid(of: current), parent != current else { break }
            current = parent
            depth += 1
        }
        return paths
    }

    /// `proc_pidpath` — the process's executable path, or nil if the pid is gone/denied.
    private static func executablePath(of pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a C macro expression (4*MAXPATHLEN) Swift can't
        // import — spell out its definition.
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The parent pid via `sysctl KERN_PROC_PID`, or nil if the pid is gone.
    private static func parentPid(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        return info.kp_eproc.e_ppid
    }
}
