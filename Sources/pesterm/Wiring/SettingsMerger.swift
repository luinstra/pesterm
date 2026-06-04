import Foundation

/// Pure, testable JSON settings merge core. Swift port of claude-notify-kit's
/// merge-settings.py semantics:
///   - load a settings object ({} if file missing; REFUSE to touch malformed JSON);
///   - upsert/remove a single hook entry for a given event, preserving ALL unrelated
///     hooks and keys (semantic preservation via JSONSerialization [String: Any]);
///   - serialize with sorted keys + trailing newline, VALIDATE by re-parsing;
///   - back up the existing file ONLY on an actual content change;
///   - atomic write via a SAME-DIRECTORY temp file + rename (no cross-device failure).
///
/// Idempotency lives at the caller layer (compare proposed-vs-current sorted
/// serialization → skip `write` on no-op). `upsert`/`remove` are deterministic so that
/// equality comparison is meaningful.
enum SettingsMerger {

    enum MergeError: Error, CustomStringConvertible {
        case malformedJSON(path: String, underlying: String)
        case notAnObject(path: String)
        case serializationFailed(String)
        case unexpectedHooksShape(found: String)
        case unexpectedEventShape(event: String, found: String)

        var description: String {
            switch self {
            case .malformedJSON(let path, let underlying):
                return "malformed JSON in \(path): \(underlying)"
            case .notAnObject(let path):
                return "settings file \(path) is not a JSON object"
            case .serializationFailed(let detail):
                return "failed to serialize settings: \(detail)"
            case .unexpectedHooksShape(let found):
                return "refusing to modify settings: \"hooks\" is present but is \(article(found)) \(found), " +
                       "not a JSON object. Fix or remove it manually so pesterm does not clobber it."
            case .unexpectedEventShape(let event, let found):
                return "refusing to modify settings: hooks[\"\(event)\"] is present but is \(article(found)) \(found), " +
                       "not a JSON array. Fix or remove it manually so pesterm does not clobber it."
            }
        }

        /// "an" before a vowel-initial type name (object, array), else "a".
        private func article(_ noun: String) -> String {
            return "aeiou".contains(noun.first ?? "x") ? "an" : "a"
        }
    }

    /// Best-effort human-readable JSON type name for an unexpected value (for errors).
    private static func jsonTypeName(_ value: Any) -> String {
        switch value {
        case is [String: Any]: return "object"
        case is [Any]:         return "array"
        case is String:        return "string"
        case is NSNull:        return "null"
        case let n as NSNumber:
            // Distinguish bool from number (JSONSerialization bridges both to NSNumber).
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return "boolean" }
            return "number"
        default:               return "value of an unexpected type"
        }
    }

    // MARK: - Load

    /// Load the settings object. Missing file → `{}` (never errors).
    /// Present-but-invalid JSON → throws `MergeError.malformedJSON` (caller exits
    /// non-zero and touches nothing). An empty/whitespace file is treated as `{}`.
    static func load(path: String) throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [:] }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw MergeError.malformedJSON(path: path, underlying: error.localizedDescription)
        }

        // Empty / whitespace-only file → {} (matches merge-settings.py leniency).
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if data.isEmpty || trimmed?.isEmpty == true { return [:] }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw MergeError.malformedJSON(path: path, underlying: error.localizedDescription)
        }
        guard let obj = parsed as? [String: Any] else {
            throw MergeError.notAnObject(path: path)
        }
        return obj
    }

    // MARK: - Pure transforms

    /// Return new settings with OUR entry as the SOLE matching entry under
    /// `hooks[event]`: every existing `isMine` entry is removed (even at a stale path),
    /// then `entry` is appended. All other event entries and unrelated keys are
    /// preserved.
    ///
    /// REFUSAL POSTURE (preserve what we don't own): a MISSING `hooks` key — or a
    /// missing event key — is fine (we create it). But a PRESENT `hooks` value that is
    /// NOT a JSON object, or a PRESENT event value that is NOT a JSON array, throws
    /// rather than being silently overwritten.
    static func upsert(_ settings: [String: Any],
                       event: String,
                       isMine: (Any) -> Bool,
                       entry: [String: Any]) throws -> [String: Any] {
        var result = settings
        var hooks = try resolveHooks(result)
        var entries = try resolveEventEntries(hooks, event: event)
        entries.removeAll { isMine($0) }
        entries.append(entry)
        hooks[event] = entries
        result["hooks"] = hooks
        return result
    }

    /// Return new settings with every `isMine` entry removed from `hooks[event]`.
    /// If the event array becomes empty it is removed; if `hooks` becomes empty it is
    /// removed. All unrelated keys/entries preserved.
    ///
    /// REFUSAL POSTURE: a MISSING `hooks`/event key is a no-op (nothing to remove). A
    /// PRESENT-but-unexpected `hooks` (not an object) or event (not an array) throws
    /// rather than clobbering — same posture as `upsert`.
    static func remove(_ settings: [String: Any],
                       event: String,
                       isMine: (Any) -> Bool) throws -> [String: Any] {
        var result = settings
        // Missing hooks → nothing to remove.
        guard result["hooks"] != nil else { return result }
        var hooks = try resolveHooks(result)
        // Missing event key → nothing to remove (but a present-wrong-type throws).
        guard hooks[event] != nil else { return result }
        var entries = try resolveEventEntries(hooks, event: event)
        entries.removeAll { isMine($0) }
        if entries.isEmpty {
            hooks.removeValue(forKey: event)
        } else {
            hooks[event] = entries
        }
        if hooks.isEmpty {
            result.removeValue(forKey: "hooks")
        } else {
            result["hooks"] = hooks
        }
        return result
    }

    /// Resolve `settings["hooks"]` as an object. Missing → fresh `{}`. Present-but-not-
    /// an-object → throw (refuse to clobber).
    private static func resolveHooks(_ settings: [String: Any]) throws -> [String: Any] {
        guard let raw = settings["hooks"] else { return [:] }
        guard let hooks = raw as? [String: Any] else {
            throw MergeError.unexpectedHooksShape(found: jsonTypeName(raw))
        }
        return hooks
    }

    /// Resolve `hooks[event]` as an array. Missing → empty array. Present-but-not-an-
    /// array → throw (refuse to clobber).
    private static func resolveEventEntries(_ hooks: [String: Any], event: String) throws -> [Any] {
        guard let raw = hooks[event] else { return [] }
        guard let entries = raw as? [Any] else {
            throw MergeError.unexpectedEventShape(event: event, found: jsonTypeName(raw))
        }
        return entries
    }

    // MARK: - Serialization

    /// Deterministic serialization: sorted keys, pretty-printed, trailing newline.
    /// Used both for the comparison (idempotency) and for the bytes written to disk.
    static func serialize(_ settings: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(settings) else {
            throw MergeError.serializationFailed("object is not valid JSON")
        }
        var data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys])
        data.append(0x0A) // trailing newline
        return data
    }

    // MARK: - Write

    /// Serialize, VALIDATE by re-parsing, back up the existing file ONLY when it exists
    /// AND its on-disk content differs from what we're about to write, then atomically
    /// write via a SAME-DIRECTORY temp file + rename. Creates parent dirs as needed.
    ///
    /// Returns the backup path if one was created, else nil.
    ///
    /// NOTE: callers should compute proposed-vs-current equality and skip `write`
    /// entirely on a no-op; this method still guards against backing up unchanged
    /// content (it compares the serialized bytes against the existing file).
    @discardableResult
    static func write(_ settings: [String: Any], to path: String) throws -> String? {
        let fm = FileManager.default
        let data = try serialize(settings)

        // Last-chance validation: the bytes we're about to land must re-parse.
        do {
            _ = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw MergeError.serializationFailed("serialized JSON did not re-parse: \(error.localizedDescription)")
        }

        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()

        // Create parent directories first if missing.
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let destExists = fm.fileExists(atPath: path)

        // Backup ONLY on an actual content change of an existing file.
        var backupPath: String?
        if destExists {
            let existing = try? Data(contentsOf: url)
            if existing != data {
                backupPath = uniqueBackupName(for: path, fm: fm)
                try fm.copyItem(at: url, to: URL(fileURLWithPath: backupPath!))
            }
        }

        // Atomic write: SAME-DIRECTORY temp file + rename. NSTemporaryDirectory() can
        // be on a different mount → cross-device rename failure. We stay beside the
        // target.
        let tmpURL = dir.appendingPathComponent(".pesterm-settings.\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmpURL, options: [.atomic])
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw error
        }

        do {
            if destExists {
                // Replace the existing file atomically.
                _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                // No existing file: replaceItemAt has awkward semantics → plain move.
                try fm.moveItem(at: tmpURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmpURL)
            throw error
        }

        return backupPath
    }

    /// `<path>.bak-YYYYMMDD-HHMMSS`, with a numeric suffix appended if a backup with
    /// that timestamp already exists (collisions happen on sub-second re-writes).
    private static func uniqueBackupName(for path: String, fm: FileManager) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(path).bak-\(fmt.string(from: Date()))"
        if !fm.fileExists(atPath: base) { return base }
        var n = 1
        while fm.fileExists(atPath: "\(base).\(n)") { n += 1 }
        return "\(base).\(n)"
    }
}
