import Foundation

/// Claude Code `PermissionRequest` hook writer. Manages a SINGLE matcher-less entry
/// whose command ends in `--adapter claude-permission`. This is the BLOCKING tool-
/// approval hook: when wired, pesterm posts an Approve/Deny notification and prints the
/// honored decision JSON. Identity (`isMine`) is the `--adapter claude-permission`
/// substring, stable regardless of the binary path.
///
/// Same agent ("claude") and settings file as `ClaudeHookWriter`, but a DIFFERENT event
/// ("PermissionRequest"). The registry returns BOTH writers for `claude`.
struct PermissionRequestHookWriter: HookWriter {
    /// The adapter flag fragment that signs pesterm's PermissionRequest hook command.
    static let adapterFlag = "--adapter claude-permission"

    let agentName = "claude"

    var settingsPath: String {
        NSHomeDirectory() + "/.claude/settings.json"
    }

    let hookEvent = "PermissionRequest"

    /// True iff `entry` is a dict with a `hooks` array containing any
    /// `{type: "command"}` whose `command` string contains `--adapter claude-permission`.
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

    /// `{"hooks":[{"type":"command","command":"<command> --adapter claude-permission"}]}`.
    /// Matcher-less for v1. The full signature accepts `sound:` and IGNORES it — there is
    /// NO `--sound` and NO `--approve-ui` on the permission hook. Reuses
    /// `ClaudeHookWriter.shellArg` for quoting (no duplication).
    func makeEntry(command: String, sound: String?) -> [String: Any] {
        _ = sound // intentionally ignored: the permission hook carries no sound override.
        let cmd = "\(ClaudeHookWriter.shellArg(command)) \(Self.adapterFlag)"
        return [
            "hooks": [
                [
                    "type": "command",
                    "command": cmd
                ]
            ]
        ]
    }
}
