import Foundation

/// One-shot finalizer. Exactly ONE of the racing finalizers — an Approve/Deny action
/// tap or the 120s fail-safe timer — must emit the decision and exit; the loser must
/// do nothing. `tryResolve()` returns `true` to the FIRST caller and `false` to every
/// caller thereafter, atomically, so there is no double-emit / double-exit / late
/// timer-after-tap.
final class ResolvedGate {
    private let lock = NSLock()
    private var resolved = false

    /// Atomically claim the resolution. Returns true to exactly one caller.
    func tryResolve() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resolved { return false }
        resolved = true
        return true
    }
}
