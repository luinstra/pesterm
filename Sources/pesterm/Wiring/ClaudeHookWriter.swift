import Foundation

/// Claude Code hook writer. Manages a SINGLE matcher-less `Notification` entry whose
/// command ends in `--adapter claude`. Identity (`isMine`) is the `--adapter claude`
/// substring in ANY hook command in the entry — stable regardless of the binary path,
/// so re-wiring at a new path removes the stale entry.
struct ClaudeHookWriter: HookWriter {
    /// The adapter flag fragment that signs pesterm's Claude hook command.
    static let adapterFlag = "--adapter claude"

    let agentName = "claude"

    var settingsPath: String {
        NSHomeDirectory() + "/.claude/settings.json"
    }

    let hookEvent = "Notification"

    /// True iff `entry` is a dict with a `hooks` array containing any
    /// `{type: "command"}` whose `command` string contains `--adapter claude`.
    func isMine(_ entry: Any) -> Bool {
        guard let dict = entry as? [String: Any],
              let hooks = dict["hooks"] as? [Any] else { return false }
        for hook in hooks {
            guard let h = hook as? [String: Any] else { continue }
            let type = h["type"] as? String
            let command = h["command"] as? String
            if type == "command",
               let command = command,
               command.contains(Self.adapterFlag) {
                return true
            }
        }
        return false
    }

    /// `{"hooks":[{"type":"command","command":"<command> --adapter claude"}]}`.
    /// Matcher-less by design (the adapter branches on `notification_type` itself).
    /// The command (and any `--sound` value) is single-quoted ONLY when it needs it: a
    /// path containing spaces or shell metacharacters (`$`, backticks, `"`, `\`) is
    /// quoted so it survives the hook runner WITHOUT any shell evaluation, while a bare
    /// command name like `pesterm` (wired when `$PREFIX/bin` is on PATH) is left clean
    /// and unquoted. `isMine` matches the `--adapter claude` substring regardless of
    /// quoting, so prior quoted/unquoted entries are still detected/replaced.
    ///
    /// When `sound` is non-nil the command gains a trailing `--sound <name>`, quoted by
    /// the same rule, overriding the per-event default sounds for this entry's events.
    func makeEntry(command: String, sound: String?) -> [String: Any] {
        var cmd = "\(Self.shellArg(command)) \(Self.adapterFlag)"
        if let sound = sound, !sound.isEmpty {
            cmd += " --sound \(Self.shellArg(sound))"
        }
        return [
            "hooks": [
                [
                    "type": "command",
                    "command": cmd
                ]
            ]
        ]
    }

    /// Render `value` for the hook command string, quoting only when necessary. A value
    /// made up solely of shell-safe characters (letters, digits, and `._-`) — i.e. a
    /// bare command name like `pesterm` — is emitted as-is. Anything else (a path, since
    /// `/` is treated as unsafe here, or any spaces/metacharacters) is POSIX
    /// single-quoted via `shellQuote`.
    static func shellArg(_ value: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        if !value.isEmpty && value.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return shellQuote(value)
    }

    /// POSIX single-quote a path for a shell command string. Single quotes suppress
    /// ALL shell evaluation (`$(...)`, backticks, `$VAR`, `"`, `\`, spaces). The only
    /// character that cannot appear literally inside single quotes is `'` itself, so
    /// every embedded `'` is closed-escaped-reopened as `'\''`.
    /// Example: `/a/b'c` → `'/a/b'\''c'`.
    static func shellQuote(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
