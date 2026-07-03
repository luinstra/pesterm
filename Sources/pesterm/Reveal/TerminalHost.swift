import Foundation

/// PURE: classify a process's ancestry (executable paths, ordered child → parent) into
/// the terminal APP hosting it. This is the tmux tier-2 dispatch key: a tmux client's
/// pid walks up to the app that spawned it, which is EVIDENCE for fronting — never a
/// guess. With two terminals open, the attached client can live in either; fronting the
/// wrong one is the bug class the D5 reorder eliminated, and this is how fronting comes
/// back without reintroducing it.
///
/// Unknown hosts classify as nil and the caller fronts NOTHING — Terminal.app (and any
/// other terminal) stays unclassified until pesterm has a revealer story for it.
enum TerminalHost {

    /// The terminals pesterm can meaningfully front. Path markers are the app-bundle
    /// directory names — stable install-location-independent identifiers (`/Applications`
    /// vs `~/Applications` vs Homebrew cask all keep the `<Name>.app/` component).
    static let knownHosts: [(marker: String, bundleID: String, appName: String)] = [
        ("/iTerm.app/", ITerm2Revealer.iTermBundleID, "iTerm2"),
        ("/Ghostty.app/", GhosttyRevealer.ghosttyBundleID, "Ghostty"),
    ]

    /// The NEAREST recognized terminal ancestor wins (paths ordered child → parent): a
    /// terminal launched from another terminal belongs to the inner one.
    static func classify(executablePaths: [String]) -> (bundleID: String, appName: String)? {
        for path in executablePaths {
            for host in knownHosts where path.contains(host.marker) {
                return (host.bundleID, host.appName)
            }
        }
        return nil
    }
}
