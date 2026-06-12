import Foundation
import ArgumentParser

/// `pesterm post ...` — defines the post flags and BUILDS a NotificationRequest.
///
/// Mb: ArgumentParser owns its own lifecycle, so this command does NOT post or spin
/// the run loop. Its job ends at producing the request; main.swift then constructs
/// NSApplication and calls app.run(). We expose `makeRequest()` for that purpose and
/// keep `run()` a no-op guard (main.swift dispatches before ArgumentParser would run).
///
/// RAW SURFACE: `post` is the unguarded path. Unlike the `--adapter` adapters it applies
/// NO mediation (the Approve/Deny denylist) and NO event suppression — it posts exactly
/// the title/body/sound handed to it. The adapters are the safe front door; `post` is the
/// primitive they (and tests/scripts) build on.
struct PostCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "post",
        abstract: "Post a clickable notification that reveals the originating terminal tab."
    )

    @Option(name: .long, help: "Notification title.")
    var title: String?

    @Option(name: .long, help: "Notification subtitle (typically the project dir).")
    var subtitle: String?

    @Option(name: .long, help: "Notification body text. Required.")
    var message: String

    @Option(name: .long, help: "Notification sound name (e.g. Hero, Morse, Pop). Run `pesterm sounds` for valid names.")
    var sound: String?

    @Option(name: .long, help: "Agent source: claude or generic. Default: generic.")
    var source: AgentSource = .default

    @Option(name: .long, help: "Coalescing group id (maps to the notification identifier).")
    var group: String?

    @Option(name: .long, help: "Max seconds the notification lives before auto-clearing (default 180; floored at 5).")
    var timeout: Double?

    /// Build the NotificationRequest from the parsed flags. Pure with respect to env.
    func makeRequest() -> NotificationRequest {
        return NotificationRequest(
            title: title ?? "pesterm",
            subtitle: subtitle,
            body: message,
            sound: sound,
            source: source,
            groupID: group,
            lifetimeSeconds: timeout
        )
    }
}
