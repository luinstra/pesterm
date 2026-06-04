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
            try backend.post(request) { [revealer] in
                // Click handler: in-process reveal, then the backend exits.
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
