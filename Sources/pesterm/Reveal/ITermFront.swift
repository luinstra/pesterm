import Foundation
import AppKit

/// Shared "bring iTerm2 to the foreground" used by BOTH the iTerm revealer and the tmux
/// revealer, so they front iTerm identically. Extracted from `ITerm2Revealer` so the tmux
/// path reuses the exact same activation (incl. the macOS 14 `.activateIgnoringOtherApps`
/// note) without instantiating an iTerm revealer (it has no session GUID under tmux).
enum ITermFront {
    /// Activate the app with `bundleID` (running → activate; not running → launch).
    static func bringToFront(bundleID: String) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if let app = running.first {
            // V5: from an LSUIElement accessory app, .activateAllWindows alone may not
            // reliably raise the app; add .activateIgnoringOtherApps.
            // NOTE: .activateIgnoringOtherApps is DEPRECATED on macOS 14+ — when the min
            // target moves to 14+, switch to the parameterless NSRunningApplication.activate().
            app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }

        // Not running. NSWorkspace has no direct "open by bundle id"; resolve via
        // LaunchServices then openApplication. (In the hook flow this is rare.)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        }
    }
}
