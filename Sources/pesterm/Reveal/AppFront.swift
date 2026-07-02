import Foundation
import AppKit

/// Shared "bring a terminal app to the foreground" used by ALL revealers (iTerm2, tmux,
/// Ghostty), so they front their app identically. Bundle-id-parameterized from day one;
/// renamed from `ITermFront` when Ghostty arrived to keep the shared-activation intent
/// honest (incl. the macOS 14 `.activateIgnoringOtherApps` note).
enum AppFront {
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
