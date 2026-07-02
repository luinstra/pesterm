import Foundation

/// PURE Ghostty env capture + cwd matching. No ScriptingBridge — all of the branching
/// logic the Ghostty reveal depends on lives here so it is unit-testable headlessly
/// (the `CGhosttyBridge` traversal delegates every decision to these functions, the
/// same split as `TmuxEnv`/`TmuxClient`).
///
/// Why cwd, not a session id: Ghostty sets no per-surface env var (no TERM_SESSION_ID
/// equivalent; ghostty discussions #9084/#10603) and its AppleScript `terminal` class
/// exposes no tty/pid (ghostty#11592). The working directory is the only env-derived
/// reveal key available today; when #11592 lands a tty property, the match key upgrades
/// to the hook's controlling tty.
enum GhosttyEnv {

    /// The exact TERM_PROGRAM value Ghostty sets (lowercase — Ghostty's own docs test
    /// `[[ "$TERM_PROGRAM" = ghostty ]]`). Case-sensitive by design.
    static let termProgramValue = "ghostty"

    /// THE single identity for a Ghostty terminal surface, used consistently everywhere
    /// one is referenced: bridge candidates map into it, `MatchChoice.one` carries it,
    /// the focus call unpacks it, tests construct it. The compound rides unconditionally
    /// (whether or not terminal ids turn out globally unique, the window/tab components
    /// are at worst redundant belt-and-braces for the re-find — never an API redesign).
    struct TerminalIdentity: Equatable {
        let windowId: String
        let tabId: String
        let terminalId: String
    }

    /// What one `pesterm_ghostty_list_terminals` entry maps to on the Swift side.
    struct Candidate: Equatable {
        let identity: TerminalIdentity
        let cwd: String
    }

    /// The outcome of matching the captured cwd against the live terminals.
    /// (Named `noMatch` — not `none` — so a `MatchChoice?` switch can never confuse it
    /// with `Optional.none`; `multiple` carries its count so the diagnostic can state
    /// it without re-deriving.)
    enum MatchChoice: Equatable {
        case one(TerminalIdentity)
        case noMatch
        case multiple(count: Int)
    }

    /// The capture result: "this IS Ghostty" plus the optional precise key. A struct
    /// (not a bare `String??`) so the two nil layers — not Ghostty at all vs Ghostty
    /// without a cwd — can never be conflated at a call site.
    struct Target: Equatable {
        /// `$PWD` when non-empty, else nil (app-only tier).
        let cwd: String?
    }

    /// Non-nil iff this env IS a Ghostty terminal (`TERM_PROGRAM == "ghostty"`, exact).
    /// This single gate feeds detection AND `CoalescingKey`, so the coalescing identity
    /// and the reveal target can never disagree.
    static func captureTarget(env: [String: String]) -> Target? {
        guard env["TERM_PROGRAM"] == termProgramValue else { return nil }
        // Gate on the TRIMMED value: a whitespace-only PWD would normalize to "" and
        // could then match a terminal reporting an empty working directory — a
        // wrong-tab risk. Whitespace-only is absent (app-only tier), like empty.
        guard let pwd = env["PWD"],
              !pwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Target(cwd: nil)
        }
        return Target(cwd: pwd)
    }

    /// Trim surrounding whitespace/newlines and strip a SINGLE trailing slash (not on
    /// "/"). Deliberately not a full canonicalizer — the symlink-resolved retry in
    /// `chooseTerminal` handles logical-vs-physical divergence separately.
    static func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    /// Decision rule (one → reveal it; zero → fall back; >1 → fall back, never guess).
    /// Two passes: exact compare of normalized paths first; only when that yields
    /// nothing, retry with symlinks resolved on BOTH sides — `$PWD` is the shell's
    /// LOGICAL path while `working directory` may be physical (e.g. /tmp vs
    /// /private/tmp). `resolvingSymlinksInPath` has documented quirks under
    /// /private//var; the retry can only ever upgrade a zero-match to a match, and a
    /// residual miss still degrades to app-front — never a wrong tab.
    static func chooseTerminal(matching cwd: String, candidates: [Candidate]) -> MatchChoice {
        let target = normalizePath(cwd)
        // Belt-and-braces behind captureTarget's whitespace gate: an empty match key
        // must never pair up with a terminal that also reports an empty working
        // directory (shell integration off) — that would be a wrong-tab guess.
        guard !target.isEmpty else { return .noMatch }
        var matches = candidates.filter { normalizePath($0.cwd) == target }
        if matches.isEmpty {
            let resolved = resolvePath(cwd)
            matches = candidates.filter { !$0.cwd.isEmpty && resolvePath($0.cwd) == resolved }
        }
        switch matches.count {
        case 0: return .noMatch
        case 1: return .one(matches[0].identity)
        default: return .multiple(count: matches.count)
        }
    }

    /// The symlink-resolved form used by `chooseTerminal`'s second pass.
    private static func resolvePath(_ path: String) -> String {
        return (normalizePath(path) as NSString).resolvingSymlinksInPath
    }

    /// PURE: the diagnostic for a reveal that fronted the app but could not focus a
    /// terminal. Grant-aware (mirror of the tmux by-tty-miss lesson): an ungranted
    /// traversal sees ZERO windows, so a `.noMatch` without the grant must name the
    /// Automation grant, not claim "no terminal in <cwd>". Every datum the text renders
    /// arrives via the signature — nothing is re-derived or guessed here.
    static func missDiagnostic(choice: MatchChoice, cwd: String,
                               grant: AutomationGrant.State) -> String {
        switch choice {
        case .one:
            // Never emitted — reveal() only asks for a diagnostic on a miss.
            return "ghostty terminal matched; revealed app only"
        case .noMatch:
            switch grant {
            case .granted:
                return "no Ghostty terminal in \(cwd) — the agent's tab may have cd'd away "
                     + "(Ghostty < 1.3 or `macos-applescript = false` also cause this); "
                     + "revealed app only"
            default:
                return "ghostty reveal blocked — Ghostty automation "
                     + "\(AutomationGrant.describe(grant, appName: "Ghostty")); "
                     + "revealed app only"
            }
        case .multiple(let count):
            return "\(count) Ghostty terminals in \(cwd); revealed app only"
        }
    }
}
