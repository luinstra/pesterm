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

    /// `{"hooks":[{"type":"command","command":"'<command>' --adapter claude"}]}`.
    /// Matcher-less by design (the adapter branches on `notification_type` itself).
    /// The executable path is POSIX single-quoted so install prefixes containing
    /// spaces (e.g. `/Users/Jane Doe/.local/bin/pesterm`) — or shell metacharacters
    /// like `$`, backticks, `"`, `\` — survive the hook runner WITHOUT any shell
    /// evaluation/expansion. `isMine` matches the `--adapter claude` substring, which
    /// quoting the path leaves intact, so prior unquoted/double-quoted entries are
    /// still detected/replaced.
    ///
    /// When `sound` is non-nil the command gains a trailing `--sound '<name>'` (the name
    /// is single-quoted with the same POSIX rule as the path), overriding the per-event
    /// default sounds for whatever events this entry handles.
    func makeEntry(command: String, sound: String?) -> [String: Any] {
        var cmd = "\(Self.shellQuote(command)) \(Self.adapterFlag)"
        if let sound = sound, !sound.isEmpty {
            cmd += " --sound \(Self.shellQuote(sound))"
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
