import Foundation
import AppKit

/// Owns the post-from-launch step. The request + revealer are stashed here BEFORE
/// app.run(); the notification is posted in applicationDidFinishLaunching so delegate
/// callbacks (didActivate/didDismissAlert) deliver on the main thread (PP1). stdin is
/// read and args parsed BEFORE this — never here.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let request: NotificationRequest
    private let revealer: TerminalRevealer?
    private let backend: NotificationBackend

    init(request: NotificationRequest,
         revealer: TerminalRevealer?,
         backend: NotificationBackend) {
        self.request = request
        self.revealer = revealer
        self.backend = backend
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try backend.post(request) { [request, revealer] actionIdentifier in
                // Click handler. For BOTH kinds, a body/default (or unknown) click
                // reveals the terminal:
                //  - INFO: the backend reveals then exits (unchanged).
                //  - PERMISSION: the backend reveals on a body click then RETURNS
                //    without resolving (keeps waiting); Approve/Deny do NOT reveal.
                // For the permission path, only a non-decision id should reveal — the
                // backend already gates Approve/Deny before invoking this closure for a
                // decision, but we double-guard here so an action tap never reveals.
                if request.kind == .permission,
                   PermissionFlow.decision(forActionIdentifier: actionIdentifier) != nil {
                    return
                }
                guard let revealer = revealer else { return }
                do {
                    try revealer.reveal()
                } catch {
                    FileHandle.standardError.write(
                        Data("pesterm: reveal failed: \(error)\n".utf8))
                }
            }
        } catch {
            FileHandle.standardError.write(
                Data("pesterm: failed to post notification: \(error)\n".utf8))
            exit(1)
        }
    }
}
