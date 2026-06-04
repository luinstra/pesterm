import Foundation

/// Shared CLI plumbing for the wire/unwire/status subcommands: stderr helpers,
/// settings equality (for idempotency), and the confirm-or-explain control flow
/// (TTY prompt vs. non-TTY safe exit).
enum Wiring {

    /// Print a message to stderr and exit non-zero. Touches nothing.
    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("pesterm: \(message)\n".utf8))
        Foundation.exit(code)
    }

    /// Print a warning to stderr (does not exit).
    static func warn(_ message: String) {
        FileHandle.standardError.write(Data("pesterm: warning: \(message)\n".utf8))
    }

    /// Compare two settings objects by their deterministic (sorted-key) serialization.
    /// This is the idempotency check: equal → no-op.
    static func equalSettings(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard let da = try? SettingsMerger.serialize(a),
              let db = try? SettingsMerger.serialize(b) else {
            return false
        }
        return da == db
    }

    /// Confirm before applying changes.
    /// - `--yes` → proceed.
    /// - non-TTY without `--yes` → print explanation + the `--yes` re-run hint and
    ///   return false (caller exits 0, touching nothing). NEVER hangs.
    /// - TTY without `--yes` → prompt `Apply these changes? [y/N]`.
    /// Returns true to proceed, false to abort.
    static func confirmOrExplain(yes: Bool, agent: String, verb: String) -> Bool {
        if yes { return true }

        if isatty(STDIN_FILENO) == 0 {
            print("Interactive confirmation unavailable; re-run with --yes to apply.")
            print("  pesterm \(verb) \(agent) --yes")
            return false
        }

        print("Apply these changes? [y/N] ", terminator: "")
        guard let line = readLine() else { return false }
        let answer = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }
}
