import Foundation
import AppKit
import ArgumentParser

/// `pesterm sample <name>` — resolve and PLAY a sound so the user can audition a
/// `--sound` value. Plays, waits for the sound to finish, then exits 0. If the name
/// does not resolve, prints an error + the `pesterm sounds` hint and exits non-zero.
///
/// PURE-ish CLI: runs and exits via main.swift's existing fallthrough BEFORE
/// NSApplication. It needs a brief run loop for NSSound playback, but it MUST terminate
/// (it never enters the notification keep-alive path). We drive a bounded RunLoop using
/// the sound's own `duration`, with a small safety cap so it can never hang.
struct SampleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sample",
        abstract: "Play a sound by name to audition it (see `pesterm sounds` for valid names)."
    )

    @Argument(help: "Sound name to play (e.g. Glass). Run `pesterm sounds` for valid names.")
    var name: String

    func run() throws {
        guard let sound = NSSound(named: NSSound.Name(name)) else {
            FileHandle.standardError.write(
                Data("pesterm: sound '\(name)' not found; run `pesterm sounds` to see valid names\n".utf8))
            Foundation.exit(1)
        }

        sound.play()

        // Bound the wait by the sound's duration (NSSound reports it once it begins),
        // with a hard cap so a misreported duration can never hang the CLI. We poll
        // `isPlaying` so the loop ends as soon as playback finishes.
        let cap: TimeInterval = 10
        let deadline = Date().addingTimeInterval(cap)
        while sound.isPlaying && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        Foundation.exit(0)
    }
}
