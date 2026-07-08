import Foundation

/// PURE tmux parsing + capture. No `Process`, no ScriptingBridge — all of the branching
/// logic the tmux reveal depends on lives here so it is unit-testable headlessly (the
/// `TmuxClient` subprocess shell delegates every decision to these functions).
enum TmuxEnv {

    /// An attached (non-control) tmux client: its tty (the iTerm by-tty match key) and
    /// its pid (the ancestry key for identifying which terminal APP hosts it — nil when
    /// tmux reported something unparseable; the client still counts for one-vs-many).
    struct Client: Equatable {
        let tty: String
        let pid: Int32?
    }

    /// The outcome of resolving the attached tmux clients for a pane's session —
    /// shared by the reveal path and the focus probe. (Named `detached`/`multiple`
    /// rather than `none`/`many` so a `ClientResolution?` switch can't confuse the
    /// `detached` case with `Optional.none` = a tmux query failure.) Carries the
    /// remote-only distinction as a FIRST-CLASS case so the reveal path's mosh/ssh
    /// diagnostic (the forgotten-remote-attach story) survives the shared extraction.
    enum ClientResolution: Equatable {
        /// Exactly one revealable client — reveal / probe it.
        case one(Client)
        /// Two+ LOCALLY-HOSTED clients — genuine ambiguity, never guess.
        case multiple
        /// No (non-control) client attached — detached → fall back.
        case detached
        /// Clients are attached, but none is hosted by a local terminal app
        /// (mosh/ssh attaches, unsupported terminals).
        case remoteOnly
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

    /// Parse `tmux list-clients -F '#{client_tty}:#{client_pid}:#{client_control_mode}'`
    /// output into the non-control clients. Fields parse from the RIGHT (a tty path
    /// `/dev/ttys003` carries no colons of its own): last = control-mode flag, second-last
    /// = pid, remainder = tty. Control-mode rows (`:1`) are dropped so an IDE/control
    /// client never becomes the reveal target. A garbage/missing pid degrades to
    /// `pid: nil` — the client still exists (one-vs-many must not change), it just can't
    /// be ancestry-classified.
    static func parseClients(listClientsOutput: String) -> [Client] {
        var clients: [Client] = []
        for rawLine in listClientsOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let lastColon = line.range(of: ":", options: .backwards) else {
                // No control-mode field — treat the whole line as a tty (defensive).
                let n = normalizeTTY(line)
                if !n.isEmpty { clients.append(Client(tty: n, pid: nil)) }
                continue
            }
            let control = String(line[lastColon.upperBound...])
            if control == "1" { continue } // skip control-mode clients
            let beforeControl = String(line[..<lastColon.lowerBound])

            let pid: Int32?
            let tty: String
            if let pidColon = beforeControl.range(of: ":", options: .backwards) {
                pid = Int32(beforeControl[pidColon.upperBound...])
                tty = normalizeTTY(String(beforeControl[..<pidColon.lowerBound]))
            } else {
                // Two-field line (old format) — tty only, no pid (defensive).
                pid = nil
                tty = normalizeTTY(beforeControl)
            }
            if !tty.isEmpty { clients.append(Client(tty: tty, pid: pid)) }
        }
        return clients
    }

    /// THE client resolution rule (replaces the former `chooseClient` +
    /// `chooseLocalClient` pair — one rule, no parallel paths). Behavior-preserving vs
    /// the old inline reveal() flow:
    ///  - 0 clients → `.detached`;
    ///  - exactly 1 → `.one` WITHOUT local filtering (matches today's reveal(), which
    ///    only filtered on the multiple case — a lone client is revealed as-is);
    ///  - 2+ → the remote-attach filter: a mosh/ssh-hosted client cannot be revealed
    ///    by a local app, so dropping it is logic, not preference (the recurring
    ///    real-world case: a forgotten remote attach sharing the session with the real
    ///    terminal tab). Exactly one local survivor → `.one`; two+ locals →
    ///    `.multiple` (genuine ambiguity, never guess); zero locals → `.remoteOnly`
    ///    (nothing local to reveal — name the invisible culprit).
    static func resolveClients(_ classified: [(client: Client, locallyHosted: Bool)]) -> ClientResolution {
        switch classified.count {
        case 0:
            return .detached
        case 1:
            return .one(classified[0].client)
        default:
            let locals = classified.filter { $0.locallyHosted }.map { $0.client }
            switch locals.count {
            case 0: return .remoteOnly
            case 1: return .one(locals[0])
            default: return .multiple
            }
        }
    }

    /// PURE: parse `display-message -p '#{window_active}#{pane_active}'` output.
    /// Trimmed output == "11" (the pane's window is the session's current window AND
    /// the pane is that window's active pane) → true; EVERYTHING else — empty, "10",
    /// "01", "0", garbage — → false (fail toward not-focused → post).
    static func parseActiveFlags(_ output: String) -> Bool {
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "11"
    }

    /// Trim surrounding whitespace/newlines (the `-F` output carries a trailing newline,
    /// and `session.tty` may too). Both tmux `client_tty` and iTerm `session.tty` report the
    /// full `/dev/ttysNNN` path, so a trimmed exact compare matches; a mismatch just falls
    /// back (never a wrong tab).
    static func normalizeTTY(_ s: String) -> String {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
