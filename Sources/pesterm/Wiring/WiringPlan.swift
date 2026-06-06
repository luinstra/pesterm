import Foundation

/// PURE settings transform: fold an agent's hook writers into a settings object,
/// producing the proposed settings to write. This is the single source of truth for the
/// wire/configure semantics — `ConfigureCommand` and the wiring tests both call it, so
/// there is no second hand-rolled copy of the loop to drift.
///
/// Semantics (mirrors the original `wire` behavior):
///  - `approvals == true`  → upsert BOTH hooks. The `Notification` (Claude) entry's
///    `notification_type` matcher OMITS `permission_prompt`, because the
///    `PermissionRequest` approval hook owns that event (otherwise one permission yields
///    two banners).
///  - `approvals == false` → upsert the `Notification` hook (matcher INCLUDES
///    `permission_prompt`, since it now owns that event) AND actively REMOVE any existing
///    `PermissionRequest` entry — so disabling approvals truly disables a previously-wired
///    approval hook rather than just skipping it.
enum WiringPlan {

    /// Build the proposed settings for wiring `agent` into `current`.
    /// - `command`: the bare executable path/name baked into each hook command.
    /// - `sound`: optional `--sound` override for the Notification hook (ignored by the
    ///   PermissionRequest hook).
    /// Throws only if `SettingsMerger` rejects the transform.
    static func build(agent: String,
                      approvals: Bool,
                      command: String,
                      sound: String?,
                      current: [String: Any]) throws -> [String: Any] {
        let writers = HookWriterRegistry.writers(for: agent)
        // Approvals are only actually wired if this agent HAS a PermissionRequest writer.
        let approvalsWired = approvals && writers.contains { $0 is PermissionRequestHookWriter }

        var proposed = current
        for writer in writers {
            if writer is PermissionRequestHookWriter && !approvals {
                // Disabling approvals: REMOVE any existing approval hook (no-op when none).
                proposed = try SettingsMerger.remove(proposed, event: writer.hookEvent,
                                                     isMine: writer.isMine)
                continue
            }

            let entry: [String: Any]
            if writer is ClaudeHookWriter {
                // Choose the matcher: when approvals are also wired, omit permission_prompt
                // (the PermissionRequest hook owns it) to avoid a double banner.
                let nw = ClaudeHookWriter(matcher: approvalsWired
                    ? ClaudeHookWriter.handledNotificationTypesNoPermission
                    : ClaudeHookWriter.handledNotificationTypes)
                entry = nw.makeEntry(command: command, sound: sound)
            } else {
                entry = writer.makeEntry(command: command, sound: sound)
            }
            proposed = try SettingsMerger.upsert(proposed, event: writer.hookEvent,
                                                 isMine: writer.isMine, entry: entry)
        }
        return proposed
    }
}
