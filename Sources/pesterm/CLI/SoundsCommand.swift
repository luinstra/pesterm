import Foundation
import ArgumentParser

/// `pesterm sounds` — list the valid `--sound` names by scanning the standard NSSound
/// directories (user → local → system). These are the authoritative values accepted by
/// `--sound` / `wire claude --sound <name>`, including any customs the user dropped in
/// `~/Library/Sounds`.
///
/// PURE CLI: runs and exits via main.swift's existing fallthrough before NSApplication.
struct SoundsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sounds",
        abstract: "List valid --sound names from the standard macOS Sounds directories."
    )

    func run() throws {
        let entries = SoundLibrary.names()
        if entries.isEmpty {
            print("No sounds found in: \(SoundLibrary.standardDirectories.joined(separator: ", "))")
            Foundation.exit(0)
        }

        // Annotate non-system entries (user/local customs) so the user can tell their
        // own drop-ins apart from the classic system sounds.
        for entry in entries {
            if entry.directory == "/System/Library/Sounds" {
                print(entry.name)
            } else {
                let source = entry.directory.hasPrefix(NSHomeDirectory()) ? "user" : "custom"
                print("\(entry.name)  (\(source): \(entry.directory))")
            }
        }
        print("")
        print("Use any name above with --sound, e.g.  pesterm wire claude --sound \(entries[0].name)")
        Foundation.exit(0)
    }
}
