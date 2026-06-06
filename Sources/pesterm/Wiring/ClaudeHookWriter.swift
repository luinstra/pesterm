import Foundation

/// Claude Code hook writer. Manages a SINGLE `Notification` entry whose command ends in
/// `--adapter claude`. The entry carries a `notification_type` matcher (Notification
/// matchers filter on `notification_type`, with `|` = OR alternation). Identity
/// (`isMine`) is the `--adapter claude` substring in ANY hook command in the entry —
/// stable regardless of the binary path or the matcher key, so re-wiring at a new path
/// removes the stale entry.
struct ClaudeHookWriter: HookWriter {
    /// The adapter flag fragment that signs pesterm's Claude hook command.
    static let adapterFlag = "--adapter claude"

    /// Matcher for the standalone / approvals-OFF case: the info hook handles ALL three
    /// notification types, including `permission_prompt`.
    static let handledNotificationTypes = "idle_prompt|permission_prompt|elicitation_dialog"

    /// Matcher for the approvals-ON case: `permission_prompt` is OMITTED because the
    /// PermissionRequest approval hook handles it — including it here too would double the
    /// banner for one permission. De-dup is done by the matcher, not by the adapter.
    static let handledNotificationTypesNoPermission = "idle_prompt|elicitation_dialog"

    let agentName = "claude"

    var settingsPath: String {
        NSHomeDirectory() + "/.claude/settings.json"
    }

    let hookEvent = "Notification"

    /// The `notification_type` matcher baked into the wired entry. Defaults to including
    /// `permission_prompt` (the standalone / approvals-off case). `wire` overrides this
    /// with `handledNotificationTypesNoPermission` when approvals are also wired. Does NOT
    /// affect `isMine` (identity is the `--adapter claude` command token).
    var matcher: String = ClaudeHookWriter.handledNotificationTypes

    /// True iff `entry` is a dict with a `hooks` array containing any
    /// `{type: "command"}` whose `command` string contains `--adapter claude` AS A WHOLE
    /// TOKEN — followed by a space or end-of-string, NOT by `-`. This token boundary is
    /// REQUIRED so `--adapter claude-permission` (the PermissionRequest hook) does NOT
    /// cross-match this Notification hook; it STILL matches `--adapter claude` and
    /// `--adapter claude --sound Glass`, and all legacy quoted/unquoted path forms.
    func isMine(_ entry: Any) -> Bool {
        guard let dict = entry as? [String: Any],
              let hooks = dict["hooks"] as? [Any] else { return false }
        for hook in hooks {
            guard let h = hook as? [String: Any] else { continue }
            let type = h["type"] as? String
            let command = h["command"] as? String
            if type == "command",
               let command = command,
               Self.commandMatchesAdapterFlag(command) {
                return true
            }
        }
        return false
    }

    /// True iff `command` contains `--adapter claude` as a whole token (followed by a
    /// space or the end of the string), but NOT `--adapter claude-permission`.
    static func commandMatchesAdapterFlag(_ command: String) -> Bool {
        var search = command.startIndex
        while let range = command.range(of: adapterFlag, range: search..<command.endIndex) {
            // The char immediately after the matched flag must be a space or end —
            // a trailing `-` (as in `claude-permission`) means this is NOT ours.
            if range.upperBound == command.endIndex {
                return true
            }
            let next = command[range.upperBound]
            if next == " " {
                return true
            }
            // Keep scanning past this occurrence (e.g. claude-permission).
            search = range.upperBound
        }
        return false
    }

    /// `{"matcher":"<matcher>","hooks":[{"type":"command","command":"<command> --adapter claude"}]}`.
    /// Carries a `notification_type` matcher (Notification matchers filter on
    /// `notification_type`, with `|` = OR alternation). The default `matcher` includes
    /// `permission_prompt`; when approvals are wired, `wire` builds the writer with the
    /// no-permission matcher so the PermissionRequest hook owns that event (no double
    /// banner). The command (and any `--sound` value) is single-quoted ONLY when it needs
    /// it: a path containing spaces or shell metacharacters (`$`, backticks, `"`, `\`) is
    /// quoted so it survives the hook runner WITHOUT any shell evaluation, while a bare
    /// command name like `pesterm` (wired when `$PREFIX/bin` is on PATH) is left clean
    /// and unquoted. `isMine` matches the `--adapter claude` substring regardless of
    /// quoting or the matcher key, so prior quoted/unquoted entries are still
    /// detected/replaced.
    ///
    /// When `sound` is non-nil the command gains a trailing `--sound <name>`, quoted by
    /// the same rule, overriding the per-event default sounds for this entry's events.
    func makeEntry(command: String, sound: String?) -> [String: Any] {
        var cmd = "\(Self.shellArg(command)) \(Self.adapterFlag)"
        if let sound = sound, !sound.isEmpty {
            cmd += " --sound \(Self.shellArg(sound))"
        }
        return [
            "matcher": matcher,
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
