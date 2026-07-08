import Foundation

/// IMPURE: fire-and-forget sound playback for the focus-suppress path (D4).
///
/// Why not NSSound: it plays asynchronously IN-PROCESS, and the suppress path calls
/// `exit(0)` immediately (the whole point is an instant Claude terminal prompt) —
/// which tears the process down and cuts playback off. Blocking until playback ends
/// would delay the prompt, defeating the feature. So we spawn `/usr/bin/afplay` on the
/// SoundLibrary-resolved file and NEVER wait: the orphaned afplay reparents to launchd
/// and exits when the (short) sound ends.
enum DetachedSound {

    /// Build the fully-configured (but UNLAUNCHED) afplay process, so a unit test can
    /// assert the fd isolation without playing audio. Nulling stdout is LOAD-BEARING:
    /// on the permission path the hook's stdout IS Claude's decision channel, and a
    /// child inheriting it could hold the pipe open or write into it. stdin/stderr are
    /// nulled with it — the child touches none of the parent's stdio.
    static func makeProcess(filePath: String) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        proc.arguments = [filePath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        return proc
    }

    /// Resolve `name` via `SoundLibrary.filePath` and play it detached. Best-effort by
    /// contract: nil/unresolvable name → no-op; launch failure (afplay missing) →
    /// silent no-op. Sound must never block or fail the suppression.
    static func play(name: String?) {
        guard let name = name,
              let path = SoundLibrary.filePath(forName: name) else { return }
        let proc = makeProcess(filePath: path)
        do {
            try proc.run() // never waited on — reparents to launchd, exits with the sound
        } catch {
            // Silent no-op: the suppression must proceed regardless.
        }
    }
}
