import Foundation
import ArgumentParser

/// `pesterm status` — report install + wiring state, and surface the running process's
/// bundle identity (Risk 1 / R2 install-time proof via `--print-identity`).
///
/// PURE CLI: runs and exits via main.swift's existing fallthrough before NSApplication.
/// (Confirms Risk 4: must return promptly, no AppKit run loop.)
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report pesterm install path, symlink/PATH state, hook wired state, and grants."
    )

    @Option(name: .long, help: "Override the settings file probed for wired state (for tests).")
    var settings: String?

    @Flag(name: .long, help: "Print only Bundle.main.bundleIdentifier and bundlePath, then exit.")
    var printIdentity: Bool = false

    func run() throws {
        if printIdentity {
            // Authoritative install-time identity proof (R2). install.sh invokes this
            // THROUGH the symlink and asserts these two values.
            let id = Bundle.main.bundleIdentifier ?? "<nil>"
            print("bundleIdentifier: \(id)")
            print("bundlePath: \(Bundle.main.bundlePath)")
            Foundation.exit(0)
        }

        let prefix = ProcessInfo.processInfo.environment["PESTERM_PREFIX"]
            ?? (NSHomeDirectory() + "/.local")
        let bundlePath = prefix + "/share/pesterm/pesterm.app"
        let binDir = prefix + "/bin"
        let symlinkPath = binDir + "/pesterm"
        let fm = FileManager.default

        print("pesterm status")
        print("")

        // Bundle install path.
        if fm.fileExists(atPath: bundlePath) {
            print("Bundle:   present  \(bundlePath)")
        } else {
            print("Bundle:   absent   \(bundlePath)")
        }

        // CLI bin entry: a symlink (legacy) OR a wrapper script (current model) that
        // `exec`s the inner bundle binary. Resolve whichever it is to a target path
        // and check whether that target leads into a pesterm.app bundle.
        if fm.fileExists(atPath: symlinkPath) {
            let target = Self.binEntryTarget(symlinkPath)
            let intoBundle = Self.leadsIntoBundle(target)
            print("Symlink:  present  \(symlinkPath)")
            print("          resolves to \(target)\(intoBundle ? "" : "  (NOT inside the bundle!)")")
        } else {
            print("Symlink:  absent   \(symlinkPath)")
        }

        // On PATH? Normalize entries before comparing.
        let onPath = Self.isOnPath(binDir)
        if onPath {
            print("PATH:     ok       \(binDir) is on PATH")
        } else {
            print("PATH:     missing  \(binDir) is NOT on PATH")
            print("          add this to your shell profile:")
            print("          export PATH=\"\(binDir):$PATH\"")
        }

        // Running process bundle identity.
        print("")
        print("Running identity:")
        print("  bundleIdentifier: \(Bundle.main.bundleIdentifier ?? "<nil>")")
        print("  bundlePath:       \(Bundle.main.bundlePath)")

        // Hook wired state per supported agent.
        print("")
        print("Hook wired state:")
        for agentName in HookWriterRegistry.supportedAgents {
            let writers = HookWriterRegistry.writers(for: agentName)
            guard let first = writers.first else { continue }
            let path = settings ?? first.settingsPath
            do {
                let s = try SettingsMerger.load(path: path)
                print("  \(agentName): (\(path))")
                for writer in writers {
                    let entries = ((s["hooks"] as? [String: Any])?[writer.hookEvent] as? [Any]) ?? []
                    let mine = entries.filter { writer.isMine($0) }
                    if mine.isEmpty {
                        print("    \(writer.hookEvent): not wired")
                    } else {
                        let cmd = Self.firstCommand(in: mine[0]) ?? "<unknown>"
                        let stale = Self.commandPathMissing(cmd)
                        print("    \(writer.hookEvent): wired")
                        print("      command: \(cmd)\(stale ? "  (STALE: path not found)" : "")")
                    }
                }
            } catch {
                print("  \(agentName): error loading \(path): \(error)")
            }
        }

        // Manual-grant reminder. Notifications is the only grant pesterm needs; macOS
        // prompts for it on the first post. (The reveal needs no Automation grant.)
        print("")
        print("Manual grant (one-time): allow notifications when macOS prompts on the first post.")

        Foundation.exit(0)
    }

    // MARK: - Helpers

    /// Normalize `dir` and each `$PATH` entry (strip trailing slash, resolve symlinks)
    /// before membership test.
    static func isOnPath(_ dir: String) -> Bool {
        let target = normalize(dir)
        let raw = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for entry in raw.split(separator: ":", omittingEmptySubsequences: true) {
            if normalize(String(entry)) == target { return true }
        }
        return false
    }

    private static func normalize(_ path: String) -> String {
        var p = (path as NSString).resolvingSymlinksInPath
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    /// First `command` string in an entry's `hooks` array.
    private static func firstCommand(in entry: Any) -> String? {
        guard let dict = entry as? [String: Any],
              let hooks = dict["hooks"] as? [Any] else { return nil }
        for hook in hooks {
            if let h = hook as? [String: Any], let c = h["command"] as? String {
                return c
            }
        }
        return nil
    }

    /// The hook command is `'<path>' --adapter claude` (path is single-quoted; older
    /// entries may be double-quoted or unquoted). Flag stale if `<path>` is gone.
    ///
    /// `<path>` may be either an absolute/relative filesystem path (the installer pins
    /// `$PREFIX/bin/pesterm` when that dir is NOT on PATH) OR a bare command name (the
    /// installer wires just `pesterm` when `$PREFIX/bin` IS on PATH). A bare name is
    /// resolved against `$PATH` the way the shell would; checking it with `fileExists`
    /// would wrongly report it stale.
    private static func commandPathMissing(_ command: String) -> Bool {
        let path = commandPath(command)
        if path.contains("/") {
            return !FileManager.default.fileExists(atPath: path)
        }
        return !resolvesOnPath(path)
    }

    /// True iff `name` resolves to an executable file on `$PATH` (shell `command -v`
    /// semantics). Used to validate a bare-name hook command.
    static func resolvesOnPath(_ name: String) -> Bool {
        let raw = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let fm = FileManager.default
        for dir in raw.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = (String(dir) as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) { return true }
        }
        return false
    }

    /// Extract the executable path from a hook command string. Current form is a
    /// leading POSIX single-quoted segment (`'…/pesterm' --adapter claude`, with any
    /// embedded `'` written `'\''`); legacy forms are a leading double-quoted segment
    /// or a bare unquoted first token.
    static func commandPath(_ command: String) -> String {
        if command.hasPrefix("'") {
            return unwrapSingleQuoted(command)
        }
        if command.hasPrefix("\"") {
            let rest = command.dropFirst()
            if let end = rest.firstIndex(of: "\"") {
                let inner = String(rest[rest.startIndex..<end])
                return inner
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
        }
        return command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
    }

    /// Unwrap a leading POSIX single-quoted segment, reversing the `'\''` escape. Starts
    /// at the leading `'`; concatenates literal runs until a closing `'` that is NOT the
    /// start of a `'\''` sequence.
    static func unwrapSingleQuoted(_ s: String) -> String {
        let chars = Array(s)
        guard chars.first == "'" else { return s }
        var i = 1
        var out = ""
        while i < chars.count {
            if chars[i] == "'" {
                // Possible `'\''` escape: ' \ ' ' (four chars starting at i).
                if i + 3 < chars.count,
                   chars[i + 1] == "\\", chars[i + 2] == "'", chars[i + 3] == "'" {
                    out.append("'")
                    i += 4
                    continue
                }
                // Closing quote of the segment.
                return out
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Resolve a bin entry (symlink or wrapper script) to the path it ultimately points
    /// at. A symlink is resolved via `resolvingSymlinksInPath`; a wrapper script's
    /// `exec "<path>" "$@"` target is parsed from its contents. Falls back to the entry
    /// path itself when neither applies.
    static func binEntryTarget(_ binEntryPath: String) -> String {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: binEntryPath)
        if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            return (binEntryPath as NSString).resolvingSymlinksInPath
        }
        // Regular file → the wrapper script. Parse the `exec "<target>"` line.
        if let contents = try? String(contentsOfFile: binEntryPath, encoding: .utf8),
           let target = execTarget(inWrapper: contents) {
            return target
        }
        return binEntryPath
    }

    /// Parse the executable target from a wrapper script's `exec '<path>' "$@"` line.
    /// Current form single-quotes the target (POSIX-escaped); legacy wrappers may
    /// double-quote or leave it unquoted.
    static func execTarget(inWrapper contents: String) -> String? {
        for rawLine in contents.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("exec ") else { continue }
            let after = line.dropFirst("exec ".count).trimmingCharacters(in: .whitespaces)
            if after.hasPrefix("'") {
                return unwrapSingleQuoted(after)
            }
            if after.hasPrefix("\"") {
                let rest = after.dropFirst()
                if let end = rest.firstIndex(of: "\"") {
                    return String(rest[rest.startIndex..<end])
                }
            }
            // Unquoted: first token after `exec`.
            return after.split(separator: " ", maxSplits: 1).first.map(String.init)
        }
        return nil
    }

    /// True iff `path` leads into a `pesterm.app` bundle.
    static func leadsIntoBundle(_ path: String) -> Bool {
        return path.contains("/pesterm.app/") || path.hasSuffix("/pesterm.app")
    }
}
