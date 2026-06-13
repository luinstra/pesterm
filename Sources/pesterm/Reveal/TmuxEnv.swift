import Foundation

/// PURE tmux parsing + capture. No `Process`, no ScriptingBridge — all of the branching
/// logic the tmux reveal depends on lives here so it is unit-testable headlessly (the
/// `TmuxClient` subprocess shell delegates every decision to these functions).
enum TmuxEnv {

    /// The outcome of inspecting the attached tmux clients for a pane's session.
    /// (Named `detached`/`multiple` rather than `none`/`many` so a `ClientChoice?` switch
    /// can't confuse the `detached` case with `Optional.none` = a tmux query failure.)
    enum ClientChoice: Equatable {
        /// Exactly one non-control client is attached — reveal its tty.
        case one(String)
        /// No (non-control) client attached — detached → fall back.
        case detached
        /// More than one client — ambiguous → fall back (decision: don't guess).
        case multiple
    }

    /// The tmux socket path = field 0 of `$TMUX` (`<socket>,<pid>,<session>`). Returns nil
    /// for empty/malformed input, INCLUDING a single-field value with no comma (we never
    /// post a tmux target we can't address) — the safe choice flagged in review.
    static func socket(fromTMUX tmux: String) -> String? {
        guard let comma = tmux.firstIndex(of: ",") else { return nil }
        let socket = String(tmux[..<comma])
        return socket.isEmpty ? nil : socket
    }

    /// (socket, pane) captured from the terminal env at detect time, or nil unless BOTH a
    /// valid `$TMUX` socket AND a non-empty `$TMUX_PANE` are present.
    static func captureTarget(env: [String: String]) -> (socket: String, pane: String)? {
        guard let tmux = env["TMUX"], let socket = socket(fromTMUX: tmux) else { return nil }
        guard let pane = env["TMUX_PANE"], !pane.isEmpty else { return nil }
        return (socket, pane)
    }

    /// Parse `tmux list-clients -F '#{client_tty}:#{client_control_mode}'` output into the
    /// non-control client ttys. The control-mode flag is the LAST colon field (a tty path
    /// `/dev/ttys003` has none of its own); control-mode rows (`:1`) are dropped so an
    /// IDE/control client never becomes the reveal target.
    static func parseClientTTYs(listClientsOutput: String) -> [String] {
        var ttys: [String] = []
        for rawLine in listClientsOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let lastColon = line.range(of: ":", options: .backwards) else {
                // No control-mode field — treat the whole line as a tty (defensive).
                let n = normalizeTTY(line)
                if !n.isEmpty { ttys.append(n) }
                continue
            }
            let control = String(line[lastColon.upperBound...])
            if control == "1" { continue } // skip control-mode clients
            let n = normalizeTTY(String(line[..<lastColon.lowerBound]))
            if !n.isEmpty { ttys.append(n) }
        }
        return ttys
    }

    /// Decision rule (lean + don't-guess): one → reveal it; zero → detached; >1 → multiple.
    static func chooseClientTTY(_ ttys: [String]) -> ClientChoice {
        switch ttys.count {
        case 0: return .detached
        case 1: return .one(ttys[0])
        default: return .multiple
        }
    }

    /// Trim surrounding whitespace/newlines (the `-F` output carries a trailing newline,
    /// and `session.tty` may too). Both tmux `client_tty` and iTerm `session.tty` report the
    /// full `/dev/ttysNNN` path, so a trimmed exact compare matches; a mismatch just falls
    /// back (never a wrong tab).
    static func normalizeTTY(_ s: String) -> String {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
