import Foundation

/// The decision pesterm hands back to Claude Code's `PermissionRequest` hook.
///
/// LOCKED CONTRACT (spike-proven on claude 2.1.165):
/// - allow  -> `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
/// - deny   -> `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}`
/// - timeout -> emit NOTHING (Claude falls back to its own terminal prompt).
///
/// DENY IS JSON `behavior:"deny"` WITH EXIT 0 — there is NO exit-2 path, NO
/// `updatedInput`, NO `always`. Every outcome exits 0.
enum PermissionDecision {
    case allow
    case deny
    case timeout

    /// PURE: the exact stdout bytes for a decision, or nil to emit nothing (timeout).
    /// Hand-built constants so tests assert byte-exact output deterministically.
    static func outputJSON(for decision: PermissionDecision) -> String? {
        switch decision {
        case .allow:
            return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#
        case .deny:
            return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
        case .timeout:
            return nil
        }
    }
}
