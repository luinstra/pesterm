import Foundation

/// Claude Code `PermissionRequest`-hook adapter. Reads the hook JSON on stdin and
/// builds a `.permission` `NotificationRequest` that shows the approvable action in
/// the body and the tool name + short session id in the title/subtitle. The reveal
/// target comes from the inherited ITERM_SESSION_ID env, NEVER from the payload
/// (key invariant — mirrors `ClaudeAdapter`).
///
/// All of the parsing and rendering here is PURE and unit-tested. The interactive
/// Approve/Deny buttons + body-click reveal live in the notification backend.
enum ClaudePermissionAdapter {

    /// A minimal structured JSON value, just enough to render `tool_input` truthfully
    /// (the real command/path/url) without pulling in `[String: Any]` non-determinism.
    enum JSONValue: Decodable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let b = try? container.decode(Bool.self) {
                self = .bool(b)
            } else if let n = try? container.decode(Double.self) {
                self = .number(n)
            } else if let s = try? container.decode(String.self) {
                self = .string(s)
            } else if let o = try? container.decode([String: JSONValue].self) {
                self = .object(o)
            } else if let a = try? container.decode([JSONValue].self) {
                self = .array(a)
            } else {
                self = .null
            }
        }

        /// The plain string for a scalar value (string/number/bool), or nil otherwise.
        var scalarString: String? {
            switch self {
            case .string(let s): return s
            case .bool(let b): return b ? "true" : "false"
            case .number(let n):
                // Render integers without a trailing ".0".
                if n == n.rounded() && abs(n) < 1e15 {
                    return String(Int64(n))
                }
                return String(n)
            default: return nil
            }
        }
    }

    /// The Claude Code `PermissionRequest` hook stdin JSON (confirmed fields). We do NOT
    /// decode `permission_mode` / `permission_suggestions` — unused in v1.
    struct PermissionPayload: Decodable {
        let toolName: String?
        let toolInput: JSONValue?
        let cwd: String?
        let sessionId: String?

        enum CodingKeys: String, CodingKey {
            case toolName = "tool_name"
            case toolInput = "tool_input"
            case cwd
            case sessionId = "session_id"
        }
    }

    /// Group prefix. DISTINCT from `ClaudeAdapter.groupPrefix` ("claude-") so the info
    /// and permission notification streams never coalesce — the UN backend uses the
    /// groupID directly as the request identifier.
    static let groupPrefix = "claude-perm-"

    /// Tool names pesterm does NOT mediate with an Approve/Deny notification. These are
    /// INTERACTIVE / meta tools whose own in-terminal UI IS the point — mediating them is
    /// absurd (you'd "approve" a question just to then answer the question, losing the
    /// prompt's content). For these the adapter emits nothing and exits 0, so Claude
    /// falls back to its native terminal UI. This is a DENYLIST, not an allowlist: every
    /// other tool (and any unknown/missing tool name) is mediated by default, so a new
    /// side-effecting tool is never silently un-gated ("silence is NOT safety").
    static let unmediatedTools: Set<String> = [
        "AskUserQuestion",
        "ExitPlanMode",
    ]

    /// PURE: should pesterm post an Approve/Deny notification for this tool? True for
    /// everything except the interactive `unmediatedTools`; true for nil/empty (mediate
    /// by default — never silently skip an unknown tool).
    static func shouldMediate(_ toolName: String?) -> Bool {
        guard let tool = toolName, !tool.isEmpty else { return true }
        return !unmediatedTools.contains(tool)
    }

    /// PURE: decode the hook JSON. Returns nil for empty/invalid input (caller
    /// suppresses + exits 0). Unit-testable without posting.
    static func parse(_ data: Data) -> PermissionPayload? {
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(PermissionPayload.self, from: data)
    }

    /// PURE: the action shown in the notification body — the REAL target, never a
    /// target-hiding generic like "<tool> permission".
    /// - Bash: the full `tool_input.command` string (OS truncates the banner; full text
    ///   is reachable via the body-click reveal).
    /// - Any other tool: a concise but TRUTHFUL rendering of `tool_input` — the real
    ///   path/url/etc, e.g. `Write <file_path>`, `WebFetch <url>`.
    static func approvableText(from payload: PermissionPayload) -> String {
        let tool = payload.toolName ?? "tool"

        if tool == "Bash", case .object(let fields)? = payload.toolInput,
           let cmd = fields["command"]?.scalarString, !cmd.isEmpty {
            return cmd
        }

        // Non-Bash (or Bash with an unexpected shape): show the most meaningful
        // target field for the tool, falling back to a compact summary that still
        // names the real targets.
        if case .object(let fields)? = payload.toolInput {
            if let target = primaryTarget(tool: tool, fields: fields) {
                return "\(tool) \(target)"
            }
            let summary = compactSummary(fields)
            if !summary.isEmpty {
                return "\(tool) \(summary)"
            }
        }

        // No structured input we can render — name the tool truthfully (no fake target).
        return tool
    }

    /// PURE: pick the single most meaningful target field for a known tool so the body
    /// reads like `Write <file_path>` / `WebFetch <url>` instead of a key dump.
    private static func primaryTarget(tool: String, fields: [String: JSONValue]) -> String? {
        let preferredKeys: [String]
        switch tool {
        case "Write", "Edit", "MultiEdit", "NotebookEdit", "Read":
            preferredKeys = ["file_path", "notebook_path", "path"]
        case "WebFetch":
            preferredKeys = ["url"]
        case "WebSearch":
            preferredKeys = ["query"]
        case "Glob", "Grep":
            preferredKeys = ["pattern", "path"]
        default:
            preferredKeys = ["command", "file_path", "path", "url", "query", "pattern"]
        }
        for key in preferredKeys {
            if let v = fields[key]?.scalarString, !v.isEmpty {
                return v
            }
        }
        return nil
    }

    /// PURE: a deterministic compact `key=value` summary of scalar fields (sorted keys),
    /// used when no preferred target key is present. Truthful — shows the real values.
    private static func compactSummary(_ fields: [String: JSONValue]) -> String {
        let parts = fields.keys.sorted().compactMap { key -> String? in
            guard let v = fields[key]?.scalarString, !v.isEmpty else { return nil }
            return "\(key)=\(v)"
        }
        return parts.joined(separator: " ")
    }

    /// PURE: a short, human-glanceable session id (first 6 chars), or "?" when absent.
    /// Used in the title/subtitle so overlapping notifications from different sessions
    /// are distinguishable.
    static func shortSessionId(_ id: String?) -> String {
        guard let id = id, !id.isEmpty else { return "?" }
        return String(id.prefix(6))
    }

    /// PURE: the banner title — includes the tool name AND short session id so the
    /// generic "Claude Code" string can't hide which call/session this is.
    static func bannerTitle(toolName: String?, sessionId: String?) -> String {
        let tool = (toolName?.isEmpty == false) ? toolName! : "tool"
        return "Claude wants to run \(tool)"
    }

    /// PURE: the banner subtitle — project (basename of cwd) + short session id.
    static func bannerSubtitle(toolName: String?, cwd: String?, sessionId: String?) -> String {
        let project = projectName(cwd: cwd)
        return "\(project) · session \(shortSessionId(sessionId))"
    }

    /// PURE: basename of cwd (mirrors `${PWD##*/}`); falls back to the process cwd.
    static func projectName(cwd: String?) -> String {
        let path: String
        if let cwd = cwd, !cwd.isEmpty {
            path = cwd
        } else {
            path = FileManager.default.currentDirectoryPath
        }
        return (path as NSString).lastPathComponent
    }

    /// PURE: build a `.permission` `NotificationRequest`. `iTermSessionId` is the iTerm2
    /// GUID from the env (NOT the payload), used ONLY for the coalescing group; the
    /// payload's `session_id` drives the human-readable short id in the title/subtitle.
    /// Returns nil only when there is nothing approvable to render (defensive).
    static func buildRequest(from payload: PermissionPayload,
                             iTermSessionId: String?) -> NotificationRequest? {
        let body = approvableText(from: payload)
        let group: String? = iTermSessionId.map { groupPrefix + $0 }
        return NotificationRequest(
            title: bannerTitle(toolName: payload.toolName, sessionId: payload.sessionId),
            subtitle: bannerSubtitle(toolName: payload.toolName, cwd: payload.cwd,
                                     sessionId: payload.sessionId),
            body: body,
            sound: "Hero",
            source: .claude,
            groupID: group,
            kind: .permission
        )
    }
}
