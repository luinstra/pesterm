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

    /// Ordered extension preference for `filePath(forName:)`'s within-directory
    /// tie-break. `.aiff` first — the entire system catalog is .aiff. NSSound's OWN
    /// within-directory extension preference is undocumented; this FIXED order is the
    /// one accepted divergence (see `filePath`).
    static let extensionPreference: [String] = ["aiff", "aif", "caf", "wav", "m4a", "m4r"]

    /// PURE: resolve a bare sound name to the file NSSound would play, for the
    /// detached-afplay suppress path. Scans `directories` in order with
    /// FIRST-DIRECTORY-WINS precedence — identical to `names(...)` and to NSSound's
    /// documented user → local → system search order, so afplay plays the same file
    /// NSSound would have on the post path. WITHIN one directory the tie-break is the
    /// fixed `extensionPreference` order; NSSound's is undocumented, so divergence is
    /// only possible when a user ships the SAME base name with TWO extensions in ONE
    /// directory — accepted and documented (deterministic beats undocumented).
    /// Unknown name / no match → nil. Injectable `fileManager` for tests.
    static func filePath(forName name: String,
                         inDirectories directories: [String] = standardDirectories,
                         fileManager: FileManager = .default) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for dir in directories {
            guard let files = try? fileManager.contentsOfDirectory(atPath: dir) else {
                continue
            }
            // Collect this directory's candidate extensions for the base name, then
            // pick by the fixed preference order (case-insensitive extension match,
            // exact base-name match — mirroring names(...)'s base extraction).
            var available = Set<String>()
            var actualFile: [String: String] = [:] // lowercased ext -> actual filename
            for file in files {
                let ext = (file as NSString).pathExtension.lowercased()
                guard soundExtensions.contains(ext) else { continue }
                let base = (file as NSString).deletingPathExtension
                guard base == trimmed else { continue }
                if available.insert(ext).inserted {
                    actualFile[ext] = file
                }
            }
            guard !available.isEmpty else { continue }
            for ext in extensionPreference where available.contains(ext) {
                return (dir as NSString).appendingPathComponent(actualFile[ext]!)
            }
        }
        return nil
    }

    /// True iff `name` resolves to a loadable system/user sound via NSSound. Used by
    /// `sample` for the not-found error. Bare names only (no extension), matching the
    /// `--sound` flag contract.
    static func resolves(_ name: String) -> Bool {
        return NSSound(named: NSSound.Name(name)) != nil
    }

    /// Tokens for `--sound` that mean "post with NO sound" (silence). Forgiving synonyms.
    static let silenceTokens: Set<String> = ["none", "off", "silent", "mute", "silence"]

    /// PURE: does this `--sound` value request silence? Case-insensitive, trimmed.
    /// nil/empty/other → false (a real sound name or the per-event default stands).
    static func isSilenceToken(_ value: String?) -> Bool {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !v.isEmpty else { return false }
        return silenceTokens.contains(v)
    }
}
