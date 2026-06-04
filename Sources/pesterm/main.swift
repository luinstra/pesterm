import Foundation
import AppKit
import ArgumentParser

// Top-level flow (PP1 + V4 + Mb): parse args / read stdin to BUILD the request, THEN
// construct NSApplication and call app.run(). ArgumentParser only builds the request;
// it never spins the run loop (don't fight its lifecycle).

/// Capture the env once. detect/reveal read the TERMINAL env (ITERM_SESSION_ID),
/// never the agent payload (key invariant).
private let env = ProcessInfo.processInfo.environment

/// Build the (request, revealer) pair, or exit 0 for suppressed/unknown adapter events.
private func buildRequestAndRevealer() -> (NotificationRequest, TerminalRevealer?) {
    let revealer = RevealerRegistry.detect(env)

    // Detect --adapter without letting ArgumentParser own flow. We dispatch on the raw
    // args: `--adapter <agent>` triggers stdin mode; otherwise fall through to the
    // standard parse (root --help, or the `post` subcommand).
    let args = Array(CommandLine.arguments.dropFirst())
    if let adapterValue = adapterArgument(in: args) {
        return buildFromAdapter(adapterValue, revealer: revealer)
    }

    // Standard parse: `post` subcommand builds the request. `--help` / errors are
    // handled by ArgumentParser (it prints and exits).
    do {
        var parsed = try RootCommand.parseAsRoot(args)
        if let post = parsed as? PostCommand {
            // The `post` subcommand's only job is to BUILD the request (Mb).
            return (post.makeRequest(), revealer)
        }
        if parsed is RootCommand {
            // Root with no subcommand and no --adapter: nothing to post. Show help.
            RootCommand.main(["--help"])
            exit(0)
        }
        // Anything else (e.g. ArgumentParser's HelpCommand from `--help`): let
        // ArgumentParser run it so it prints help/usage, then exit cleanly.
        try parsed.run()
        exit(0)
    } catch {
        // ArgumentParser prints usage/help and exits with the right code.
        RootCommand.exit(withError: error)
    }
}

/// Extract the value of `--adapter` from raw args, supporting both `--adapter claude`
/// and `--adapter=claude`. Returns nil if not present.
private func adapterArgument(in args: [String]) -> String? {
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--adapter" {
            return i + 1 < args.count ? args[i + 1] : ""
        }
        if arg.hasPrefix("--adapter=") {
            return String(arg.dropFirst("--adapter=".count))
        }
        i += 1
    }
    return nil
}

/// Adapter mode: read ALL of stdin (readDataToEndOfFile — returns at EOF incl. empty;
/// V4), map to a request, or exit 0 on suppress/unknown (C3).
private func buildFromAdapter(_ adapter: String, revealer: TerminalRevealer?)
    -> (NotificationRequest, TerminalRevealer?) {
    guard adapter == "claude" else {
        FileHandle.standardError.write(
            Data("pesterm: unknown adapter '\(adapter)'\n".utf8))
        exit(2)
    }

    // Read stdin BEFORE NSApp.run() (PP1). readDataToEndOfFile returns at EOF.
    let data = FileHandle.standardInput.readDataToEndOfFile()

    guard let payload = ClaudeAdapter.parse(data) else {
        FileHandle.standardError.write(
            Data("pesterm: empty or invalid Claude hook JSON; nothing posted\n".utf8))
        exit(0)
    }

    // iTerm2 session id from the env (NOT payload). Used only for the coalescing group.
    let iTermSessionId = iTermSessionIdFromEnv()

    guard let request = ClaudeAdapter.buildRequest(from: payload, iTermSessionId: iTermSessionId) else {
        // Suppressed (auth_success) or unknown/missing type. Log + exit 0 (C3).
        let type = payload.notificationType ?? "<missing>"
        if type == "auth_success" {
            FileHandle.standardError.write(
                Data("pesterm: auth_success suppressed for parity\n".utf8))
        } else {
            FileHandle.standardError.write(
                Data("pesterm: unknown notification_type '\(type)' suppressed\n".utf8))
        }
        exit(0)
    }

    return (request, revealer)
}

/// The iTerm2 session GUID from the inherited env (last colon-component, PP2), or nil.
private func iTermSessionIdFromEnv() -> String? {
    guard let raw = env["ITERM_SESSION_ID"], !raw.isEmpty else { return nil }
    return ITerm2Revealer.parseSessionId(raw)
}

// MARK: - Entry point

let (request, revealer) = buildRequestAndRevealer()

// THEN construct AppKit and run the loop so delegate callbacks deliver (PP1).
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // matches LSUIElement; no Dock/menu-bar presence.

let backend: NotificationBackend = NSUserNotificationBackend()
let delegate = AppDelegate(request: request, revealer: revealer, backend: backend)
app.delegate = delegate

app.run()
