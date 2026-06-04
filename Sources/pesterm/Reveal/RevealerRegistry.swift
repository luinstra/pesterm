import Foundation

/// Holds the known revealers and picks the first match. iTerm2 first. Adding a
/// terminal = appending a type here + one new conformance.
enum RevealerRegistry {
    static let revealers: [TerminalRevealer.Type] = [
        ITerm2Revealer.self
    ]

    /// Returns the first revealer whose `detect` matches `env`, else nil.
    static func detect(_ env: [String: String]) -> TerminalRevealer? {
        for type in revealers {
            if let revealer = type.detect(env) {
                return revealer
            }
        }
        return nil
    }
}
