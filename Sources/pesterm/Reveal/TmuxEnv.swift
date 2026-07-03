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

    /// The outcome of inspecting the attached tmux clients for a pane's session.
    /// (Named `detached`/`multiple` rather than `none`/`many` so a `ClientChoice?` switch
    /// can't confuse the `detached` case with `Optional.none` = a tmux query failure.)
    enum ClientChoice: Equatable {
        /// Exactly one non-control client is attached — reveal it.
        case one(Client)
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

    /// Decision rule (lean + don't-guess): one → reveal it; zero → detached; >1 → multiple.
    static func chooseClient(_ clients: [Client]) -> ClientChoice {
        switch clients.count {
        case 0: return .detached
        case 1: return .one(clients[0])
        default: return .multiple
        }
    }

    /// PURE: among MULTIPLE attached clients, keep only the locally-hosted ones — a
    /// mosh/ssh-hosted client cannot be revealed by a local app, so dropping it is
    /// logic, not preference (the recurring real-world case: a forgotten remote attach
    /// sharing the session with the real terminal tab). Exactly one local survivor →
    /// `.one` (full precision proceeds); two+ locals → `.multiple` (genuine ambiguity,
    /// never guess); zero locals → `.detached` (nothing local to reveal).
    static func chooseLocalClient(_ classified: [(client: Client, locallyHosted: Bool)]) -> ClientChoice {
        return chooseClient(classified.filter { $0.locallyHosted }.map { $0.client })
    }

    /// Trim surrounding whitespace/newlines (the `-F` output carries a trailing newline,
    /// and `session.tty` may too). Both tmux `client_tty` and iTerm `session.tty` report the
    /// full `/dev/ttysNNN` path, so a trimmed exact compare matches; a mismatch just falls
    /// back (never a wrong tab).
    static func normalizeTTY(_ s: String) -> String {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
