import Foundation

/// The outcome of a focus probe. TWO-STATE by design: "murky" can never be conflated
/// with "yes". Every path that is not a proven hard YES — probe timeout, missing
/// Automation grant, unsupported terminal, another tab focused, garbage output — is
/// `.unverified`, and an unverified event posts exactly like today (fail toward the
/// notification; never strand an approval on a guess).
enum FocusVerdict: Equatable {
    /// The asking terminal session is PROVABLY frontmost/focused right now.
    case focused
    /// Anything less than a hard YES. The reason string is OBSERVABILITY, not a
    /// decision input: it is Trace-logged at the probe layer and never carried
    /// forward by `FocusAction` (see `FocusPolicy.action`).
    case unverified(String)
}

/// What `main.swift` does with a `.post` adapter outcome after the focus check.
enum FocusAction: Equatable {
    /// Post the notification — today's flow, byte-for-byte.
    /// Deliberately BARE: `unverified` reasons do NOT ride here (they were already
    /// Trace-logged at the probe layer); the composition root has zero decision logic.
    case post
    /// Suppress the notification: play `soundName` detached (nil = silent), write
    /// `diagnostic` to stderr, emit NOTHING on stdout, exit 0 — the proven
    /// timeout/fallback contract. On `.permission` this makes Claude render its
    /// terminal prompt instantly.
    case suppress(soundName: String?, diagnostic: String)
}

/// PURE focus-deferral decisions (focus-aware notification deferral). The impure
/// inputs — frontmost bundle id, probe reads — are gathered by the callers; every
/// branching decision lives here so it is unit-testable headlessly (the same
/// `TmuxEnv`/`TmuxClient` split discipline).
enum FocusPolicy {

    /// Tier 0: is the expected host terminal app the frontmost application?
    /// nil on either side → false (unknown never counts as frontmost).
    static func hostIsFrontmost(expectedBundleID: String?, frontmostBundleID: String?) -> Bool {
        guard let expected = expectedBundleID, !expected.isEmpty,
              let frontmost = frontmostBundleID, !frontmost.isEmpty else { return false }
        return expected == frontmost
    }

    /// THE suppress/post decision. Returns `.suppress` iff the verdict is `.focused`
    /// AND the probing terminal supports suppression for this kind — every other
    /// combination is the bare `.post`. `action` inspects only the verdict's CASE,
    /// never its payload: an `.unverified(reason)` maps to `.post` regardless of the
    /// reason's content (reasons are Trace-logged at the probe layer, D3).
    ///
    /// `resolvedSound` is the request's FINAL sound (all overrides applied — nil when
    /// `--sound none` silenced it) so the suppressed event's audible cue is exactly the
    /// sound the posted notification would have played.
    static func action(kind: NotificationKind, verdict: FocusVerdict,
                       probeSupportsKind: Bool, resolvedSound: String?) -> FocusAction {
        guard probeSupportsKind, case .focused = verdict else { return .post }
        return .suppress(soundName: resolvedSound, diagnostic: diagnostic(for: kind))
    }

    /// The stderr line for a suppressed event — states what happened and why nothing
    /// was posted (stderr only; stdout stays EMPTY, it is Claude's decision channel).
    static func diagnostic(for kind: NotificationKind) -> String {
        switch kind {
        case .permission:
            return "pesterm: terminal focused — permission prompt falls back to "
                 + "Claude's terminal UI; nothing posted"
        case .info:
            return "pesterm: terminal focused — notification suppressed; nothing posted"
        }
    }
}
