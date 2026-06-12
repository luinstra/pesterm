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
        // Optional `--sound <name>` (or `--sound=<name>`) OVERRIDES the event's default
        // sound for whatever events this hook entry handles. Optional `--timeout <seconds>`
        // OVERRIDES this notification's lifetime (info hard-cap / permission fail-safe wait).
        let soundOverride = soundArgument(in: args)
        let timeoutOverride = timeoutArgument(in: args)
        return buildFromAdapter(adapterValue, soundOverride: soundOverride,
                                timeoutOverride: timeoutOverride, revealer: revealer)
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
        // Fallthrough for PURE-CLI subcommands and ArgumentParser's own commands.
        //
        // The wire/unwire/status subcommands intentionally run-and-exit HERE: their
        // real work lives in `run()` and they call `exit()` themselves before this
        // line ever returns. They fail the `post` and bare-`RootCommand` checks above,
        // so they land here and execute BEFORE any NSApplication is constructed — they
        // must NEVER spin the AppKit run loop. `post` is handled in its own branch
        // above precisely because its `run()` is a no-op (it only builds a request),
        // and it needs AppKit to actually deliver the notification.
        //
        // GUARD NOTE: any FUTURE subcommand that NEEDS AppKit (i.e. must post a
        // notification) CANNOT reuse this fallthrough as-is. It would `run()` and
        // exit(0) here, never reaching `app.run()` below, so the notification would
        // never deliver. Such a command must be routed through the request-building
        // path (like `post`): add an explicit `if let X = parsed as? FooCommand`
        // branch above that returns a (request, revealer) instead of running here.
        //
        // This also handles ArgumentParser's HelpCommand from `--help`: it prints
        // usage and exits cleanly.
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

/// Extract the value of `--sound` from raw args, supporting both `--sound <name>` and
/// `--sound=<name>`. Returns nil if not present (defaults stand). Empty value (`--sound`
/// with no following token) returns nil so a stray flag never wipes the default.
private func soundArgument(in args: [String]) -> String? {
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--sound" {
            if i + 1 < args.count, !args[i + 1].isEmpty {
                return args[i + 1]
            }
            return nil
        }
        if arg.hasPrefix("--sound=") {
            let value = String(arg.dropFirst("--sound=".count))
            return value.isEmpty ? nil : value
        }
        i += 1
    }
    return nil
}

/// Extract the value of `--timeout` from raw args, supporting `--timeout <seconds>` and
/// `--timeout=<seconds>`. Returns nil if absent, empty, or non-positive (defaults stand) —
/// a stray/garbage flag never overrides the safe default. The backend clamps the value.
private func timeoutArgument(in args: [String]) -> TimeInterval? {
    func parse(_ s: String) -> TimeInterval? {
        guard let v = TimeInterval(s), v > 0 else { return nil }
        return v
    }
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--timeout" {
            return i + 1 < args.count ? parse(args[i + 1]) : nil
        }
        if arg.hasPrefix("--timeout=") {
            return parse(String(arg.dropFirst("--timeout=".count)))
        }
        i += 1
    }
    return nil
}

/// Adapter mode: look up the agent adapter for `--adapter <value>`, read ALL of stdin
/// (readDataToEndOfFile — returns at EOF incl. empty; V4), and map it to an outcome.
/// An UNKNOWN adapter exits 2; a suppression logs its diagnostic + exits 0 (C3); a post
/// returns the request so the keep-alive/AppDelegate/backend machinery runs (heeding the
/// GUARD NOTE above — the permission path needs `app.run()` to deliver and wait).
///
/// Dispatch goes through `AdapterRegistry`, so adding an agent is a new `AgentAdapter`
/// conformance + one registry line — this function never names a concrete adapter.
private func buildFromAdapter(_ adapter: String, soundOverride: String?,
                              timeoutOverride: TimeInterval?,
                              revealer: TerminalRevealer?)
    -> (NotificationRequest, TerminalRevealer?) {
    guard let adapterType = AdapterRegistry.adapter(for: adapter) else {
        FileHandle.standardError.write(
            Data("pesterm: unknown adapter '\(adapter)'\n".utf8))
        exit(2)
    }

    // Read stdin BEFORE NSApp.run() (PP1). readDataToEndOfFile returns at EOF.
    let data = FileHandle.standardInput.readDataToEndOfFile()

    // iTerm2 session id from the env (NOT payload). Used only for reveal/coalescing.
    let iTermSessionId = iTermSessionIdFromEnv()

    switch adapterType.outcome(stdin: data, iTermSessionId: iTermSessionId,
                               soundOverride: soundOverride) {
    case .post(var request):
        request.lifetimeSeconds = timeoutOverride
        return (request, revealer)
    case .suppress(let message):
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(0)
    }
}

/// The iTerm2 session GUID from the inherited env (last colon-component, PP2), or nil.
private func iTermSessionIdFromEnv() -> String? {
    guard let raw = env["ITERM_SESSION_ID"], !raw.isEmpty else { return nil }
    return ITerm2Revealer.parseSessionId(raw)
}

// MARK: - Entry point

let (builtRequest, revealer) = buildRequestAndRevealer()
var request = builtRequest
// Embed the reveal target in the request so it rides in the notification's userInfo: a
// click delivered to ANY pesterm process then reveals THIS notification's tab, not the
// receiver's own (W4 — same misrouting root cause as the permission decision handoff).
request.revealUserInfo = revealer?.revealUserInfo

// Diagnostic dry-run: when PESTERM_PRINT_REQUEST is set, print the BUILT request
// (title/subtitle/body/sound/group) and exit 0 WITHOUT posting or spinning AppKit.
// Lets the install/verify flow assert the resolved sound (e.g. a --sound override)
// deterministically and without keep-alive. No effect when the env var is unset.
if env["PESTERM_PRINT_REQUEST"] != nil {
    print("title: \(request.title)")
    print("subtitle: \(request.subtitle ?? "<nil>")")
    print("body: \(request.body)")
    print("sound: \(request.sound ?? "<nil>")")
    print("group: \(request.groupID ?? "<nil>")")
    exit(0)
}

// THEN construct AppKit and run the loop so delegate callbacks deliver (PP1).
let app = NSApplication.shared
app.setActivationPolicy(.accessory) // matches LSUIElement; no Dock/menu-bar presence.

let backend: NotificationBackend = UNUserNotificationBackend()
let delegate = AppDelegate(request: request, revealer: revealer, backend: backend)
app.delegate = delegate

app.run()
