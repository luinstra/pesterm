import Foundation

/// Cross-process handoff for permission decisions.
///
/// macOS delivers a notification's action tap to ONE delegate per bundle id — effectively
/// the last-registered/frontmost process, NOT necessarily the process that POSTED that
/// notification. So with several concurrent pesterm permission processes alive at once, a
/// tap can land on the wrong process (confirmed empirically: a two-process repro lost one
/// approval entirely). The fix: whichever process RECEIVES a tap writes the decision to a
/// file keyed by the RESPONSE's notification id; the process that OWNS that id polls for it
/// and picks it up wherever it landed.
///
/// Ids are unique per request (a UUID), so exactly one process ever polls a given id — no
/// reader contention. Writes are atomic (temp + rename) so a poller never reads a partial
/// file. The owning process `take`s (reads + removes) its file; orphans from dead processes
/// are swept by age at post() time.
enum DecisionStore {

    /// Default store: `~/.local/state/pesterm/decisions`. Overridable (the `dir` params) so
    /// tests don't touch the real home directory.
    static var directory: String { NSHomeDirectory() + "/.local/state/pesterm/decisions" }

    /// Write `decision` for `id`, atomically. Best-effort: failures are swallowed (the
    /// fail-safe timeout still backstops a lost decision). `.timeout` writes nothing —
    /// there is no "decision" to hand off.
    static func write(_ decision: PermissionDecision, forId id: String, dir: String = directory) {
        guard let token = token(for: decision) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = dir + "/" + sanitized(id)
        let tmp = dest + "." + ProcessInfo.processInfo.globallyUniqueString + ".tmp"
        guard (try? token.write(toFile: tmp, atomically: false, encoding: .utf8)) != nil else { return }
        try? fm.removeItem(atPath: dest) // clear any stale file for this id
        do {
            try fm.moveItem(atPath: tmp, toPath: dest) // atomic rename within the dir
        } catch {
            try? fm.removeItem(atPath: tmp)
        }
    }

    /// Read + REMOVE the decision for `id`, or nil if none has been written yet. Called by
    /// the owning process while polling; removal cleans up and prevents double-processing.
    static func take(id: String, dir: String = directory) -> PermissionDecision? {
        let p = dir + "/" + sanitized(id)
        guard let raw = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(atPath: p)
        return decision(for: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Best-effort removal of decision files older than `maxAge` — orphans whose owning
    /// process died (timed out / crashed) before polling. Keeps the dir from growing.
    static func sweepStale(maxAge: TimeInterval = 600, dir: String = directory) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        let now = Date()
        for name in names {
            let p = dir + "/" + name
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(mtime) > maxAge {
                try? fm.removeItem(atPath: p)
            }
        }
    }

    // MARK: - Encoding

    /// Filesystem-safe filename. Ids are UUIDs today, but be defensive about stray chars.
    private static func sanitized(_ id: String) -> String {
        String(id.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? $0 : "_" })
    }

    private static func token(for decision: PermissionDecision) -> String? {
        switch decision {
        case .allow: return "allow"
        case .deny: return "deny"
        case .timeout: return nil
        }
    }

    private static func decision(for token: String) -> PermissionDecision? {
        switch token {
        case "allow": return .allow
        case "deny": return .deny
        default: return nil
        }
    }
}
