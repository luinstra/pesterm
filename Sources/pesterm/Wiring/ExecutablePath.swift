import Foundation

/// Resolve the running executable to an absolute, symlink-resolved path, and detect
/// whether it lives inside a `.app` bundle.
enum ExecutablePath {

    /// Absolute, symlink-resolved path of the running executable.
    /// Prefers `Bundle.main.executablePath`; falls back to resolving
    /// `CommandLine.arguments[0]`.
    static func resolvedRunningExecutablePath() -> String {
        if let exe = Bundle.main.executablePath {
            return resolve(exe)
        }
        let arg0 = CommandLine.arguments.first ?? "pesterm"
        return resolve(arg0)
    }

    /// True iff the resolved path is inside a `.app/Contents/MacOS/` bundle.
    static func isInsideAppBundle(_ path: String) -> Bool {
        return path.contains(".app/Contents/MacOS/")
    }

    /// Resolve a possibly-relative, possibly-symlinked path to an absolute real path.
    private static func resolve(_ path: String) -> String {
        let fm = FileManager.default
        var p = path
        // Make absolute relative to cwd if needed.
        if !(p as NSString).isAbsolutePath {
            p = (fm.currentDirectoryPath as NSString).appendingPathComponent(p)
        }
        // Resolve symlinks to the real bundle binary path.
        let resolved = (p as NSString).resolvingSymlinksInPath
        return resolved
    }
}
