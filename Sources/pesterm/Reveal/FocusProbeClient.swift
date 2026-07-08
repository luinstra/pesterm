import Foundation

/// IMPURE, thin parent-side wrapper around the focus-probe CHILD (D6): re-executes
/// pesterm as `<self> _focus-probe <variant>` via `Subprocess` and applies the
/// canonical child-failure contract. No branching decisions beyond that contract —
/// every comparison against the returned value happens in the pure layer.
enum FocusProbeClient {

    /// Run the probe child and return the observed raw value, or nil.
    ///
    /// Child-failure contract (D6, canonical): exactly ONE non-empty trimmed stdout
    /// line = the observed value; empty, whitespace-only, or multi-line output = nil.
    /// The child's EXIT CODE IS IGNORED — stdout content is the only discriminator.
    /// Launch failure / timeout (child SIGTERMed) → nil too. nil → the caller maps to
    /// `.unverified` → post.
    ///
    /// The own-executable path comes from the EXISTING
    /// `ExecutablePath.resolvedRunningExecutablePath()` (handles symlinks and relative
    /// arg0) — never inlined resolution.
    static func readValue(variant: String, timeout: TimeInterval) -> String? {
        let exe = ExecutablePath.resolvedRunningExecutablePath()
        return value(fromRunResult: Subprocess.run(exe: exe, args: ["_focus-probe", variant],
                                                   timeout: timeout))
    }

    /// PURE: map a `Subprocess.run` result to the observed value. nil result (launch
    /// failure / timeout, child SIGTERMed) → nil; otherwise the STDOUT-CONTENT-ONLY
    /// contract — `result.status` is deliberately never inspected (D6: the child's
    /// exit code is ignored; `Subprocess` still surfaces it for TmuxClient consumers).
    static func value(fromRunResult result: (status: Int32, stdout: String)?) -> String? {
        guard let result = result else { return nil }
        return value(fromChildStdout: result.stdout)
    }

    /// PURE: apply the stdout-content-only contract to a child's captured stdout.
    /// Exactly one non-empty trimmed line → that line; anything else → nil.
    static func value(fromChildStdout stdout: String) -> String? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Multi-line output (e.g. a cwd containing a newline, or garbage) → nil:
        // a pathological value may only ever cause a redundant post, never a match.
        guard !trimmed.contains("\n") else { return nil }
        return trimmed
    }
}
