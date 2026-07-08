import Foundation
import ArgumentParser
import CITermBridge
import CGhosttyBridge

/// Hidden focus-probe CHILD (focus-aware notification deferral, D6). The parent
/// re-executes pesterm as `pesterm _focus-probe <variant>` so the ScriptingBridge read
/// runs in a DISPOSABLE process: a wedged Apple Event wedges only this child, which the
/// parent SIGTERMs at its deadline — never the hook process itself, and never SB off
/// the main thread.
///
/// PURE-CLI: never posts a notification, never constructs NSApplication — the
/// main.swift run-and-exit fallthrough is the CORRECT path for this subcommand per the
/// GUARD NOTE there (same shape as configure/unwire/status). The synchronous SB send
/// needs no run loop (in-repo precedent for pre-AppKit Apple-Events machinery in a
/// pure-CLI flow: `AutomationGrant.check` inside `pesterm status`).
///
/// RE-ENTRANCY SAFE by construction: the child is invoked WITHOUT `--adapter` and with
/// a pure-CLI subcommand, so it takes the run-and-exit path — it can never probe, post,
/// or recursively spawn further probe children.
///
/// Child-failure contract (D6, canonical): print the observed raw value as ONE stdout
/// line and exit 0; on ANY failure print nothing (still exit 0). The parent
/// (`FocusProbeClient`) discriminates on stdout content only — the exit code is ignored.
/// The child only OBSERVES; every comparison happens in the parent's pure layer.
struct FocusProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_focus-probe",
        abstract: "Internal focus probe (prints a raw observed value; not for direct use).",
        shouldDisplay: false
    )

    @Argument(help: "Probe variant: iterm-session-id | iterm-session-tty | ghostty-cwd")
    var variant: String

    func run() throws {
        switch variant {
        case "iterm-session-id":
            if let id = pesterm_iterm_frontmost_session_id(ITerm2Revealer.iTermBundleID) {
                print(id)
            }
        case "iterm-session-tty":
            if let tty = pesterm_iterm_frontmost_session_tty(ITerm2Revealer.iTermBundleID) {
                print(tty)
            }
        case "ghostty-cwd":
            if let cwd = pesterm_ghostty_focused_terminal_cwd(GhosttyRevealer.ghosttyBundleID) {
                print(cwd)
            }
        default:
            // Unknown variant → print nothing, exit 0 (the D6 contract: the parent
            // reads "no value" and posts; never a hook-failure-looking exit code).
            break
        }
    }
}
