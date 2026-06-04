import Foundation
import ArgumentParser

/// Root command. Supports `pesterm post ...` and `pesterm --adapter claude`
/// (stdin JSON mode). Used purely for parsing + `--help` generation; main.swift
/// owns the NSApplication lifecycle (Mb).
struct RootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pesterm",
        abstract: "pesterm — your CLI agent pesters you back to the right terminal tab.",
        subcommands: [PostCommand.self, WireCommand.self, UnwireCommand.self, StatusCommand.self]
    )

    @Option(name: .long, help: "Read an agent's hook JSON on stdin. Supported: claude.")
    var adapter: String?
}
