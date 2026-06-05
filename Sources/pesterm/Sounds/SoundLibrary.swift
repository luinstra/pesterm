import Foundation
import AppKit

/// Discovery + resolution for notification sounds. NSSound resolves a bare name
/// (no extension) against the standard Sounds directories; this type exposes that set
/// authoritatively (`pesterm sounds`) and previews a name (`pesterm sample <name>`).
///
/// PURE/testable scanning lives in `names(inDirectories:fileManager:)`; resolution
/// lives in `resolves(_:)` (delegates to NSSound). The CLI subcommands are thin
/// wrappers over these so the logic is unit-testable without audio.
enum SoundLibrary {

    /// The standard NSSound search directories, in NSSound's own precedence order
    /// (user → local → system). A bare `--sound <name>` resolves against these.
    static let standardDirectories: [String] = [
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds"),
        "/Library/Sounds",
        "/System/Library/Sounds"
    ]

    /// Sound file extensions NSSound can load (lowercased, no dot).
    static let soundExtensions: Set<String> = ["aiff", "aif", "caf", "wav", "m4a", "m4r"]

    /// A discovered sound: its base name (no extension) and the directory it came from.
    struct Entry: Equatable {
        let name: String
        /// Absolute directory the file was found in.
        let directory: String
    }

    /// PURE: scan `directories` for sound files and return their deduped, sorted base
    /// names. Non-sound files are ignored. When the same base name appears in multiple
    /// directories the FIRST directory (by the order given) wins — matching NSSound's
    /// user→local→system precedence when `standardDirectories` is passed. Injectable
    /// `fileManager` keeps this testable against a temp dir.
    static func names(inDirectories directories: [String],
                      fileManager: FileManager = .default) -> [Entry] {
        var seen = Set<String>()
        var entries: [Entry] = []
        for dir in directories {
            guard let files = try? fileManager.contentsOfDirectory(atPath: dir) else {
                continue
            }
            for file in files {
                let ext = (file as NSString).pathExtension.lowercased()
                guard soundExtensions.contains(ext) else { continue }
                let base = (file as NSString).deletingPathExtension
                guard !base.isEmpty, !seen.contains(base) else { continue }
                seen.insert(base)
                entries.append(Entry(name: base, directory: dir))
            }
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Convenience over the standard dirs.
    static func names() -> [Entry] {
        names(inDirectories: standardDirectories)
    }

    /// True iff `name` resolves to a loadable system/user sound via NSSound. Used by
    /// `sample` for the not-found error. Bare names only (no extension), matching the
    /// `--sound` flag contract.
    static func resolves(_ name: String) -> Bool {
        return NSSound(named: NSSound.Name(name)) != nil
    }
}
