import Foundation

/// How precisely a terminal can be revealed.
/// - `.precise`: focus the exact tab/session (iTerm2 via ScriptingBridge).
/// - `.appOnly`: bring the terminal app to front, no exact tab.
/// - `.none`: banner with no click action.
enum RevealCapability {
    case precise
    case appOnly
    case none
}
