/*
 * iTermBridge.m — empty @implementation blocks for the sdp-generated ScriptingBridge
 * classes.
 *
 * Why this exists: sdp generates only an interface header (iTermBridge.h). The classes
 * (iTermBridgeApplication, etc.) are dynamically vivified by ScriptingBridge at runtime
 * when SBApplication(bundleIdentifier:) is initialized. However, a Swift `as?` downcast
 * to a concrete generated class emits a link-time reference to the Objective-C class
 * symbol (_OBJC_CLASS_$_iTermBridgeApplication). Without an @implementation those symbols
 * do not exist and linking fails ("Undefined symbols ... _OBJC_CLASS_$_iTermBridgeApplication").
 *
 * These empty @implementation blocks materialize the class symbols so the binary links.
 * At runtime SBApplication returns its own dynamic subclass that is a kind-of these
 * declared classes, so the downcast and the SBElementArray traversal work as generated.
 *
 * Note: the plan's `dummy.c` is the C token source; this .m provides the ObjC class
 * symbols. The header is still consumed by Swift via `import CITermBridge`.
 */

#import "include/iTermBridge.h"

// These @implementation blocks are INTENTIONALLY empty (see file header): every method —
// whether declared directly on the interface or inherited from the generated
// iTermBridgeGenericMethods protocol — is provided dynamically by ScriptingBridge at
// runtime, not here. -Wincomplete-implementation and -Wprotocol flag exactly that
// "declared but not implemented" shape, so silence both for just these stub blocks — a
// scoped pragma, not a blanket flag, so nothing else is hidden.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"

@implementation iTermBridgeApplication
@end

@implementation iTermBridgeWindow
@end

@implementation iTermBridgeTab
@end

@implementation iTermBridgeSession
@end

#pragma clang diagnostic pop

/*
 * pesterm_reveal_iterm_session — the actual reveal traversal, done in Objective-C.
 *
 * The hierarchy is one-directional (a session has no back-pointer to its tab, a tab
 * none to its window), so we retain the enclosing loop variables and select
 * window -> tab -> session on a match. These Apple Events are self-automation (pesterm
 * runs as an iTerm descendant), so macOS requires no Automation (TCC) grant in the normal
 * case — and prompts on its own in any edge case that does.
 */
BOOL pesterm_reveal_iterm_session(NSString *targetSessionId, NSString *bundleId) {
    if (targetSessionId == nil || bundleId == nil) {
        return NO;
    }

    iTermBridgeApplication *app =
        (iTermBridgeApplication *)[SBApplication
            applicationWithBundleIdentifier:bundleId];
    if (app == nil) {
        return NO;
    }

    for (iTermBridgeWindow *window in app.windows) {
        for (iTermBridgeTab *tab in window.tabs) {
            for (iTermBridgeSession *session in tab.sessions) {
                NSString *sid = session.id;
                if (sid != nil && [sid isEqualToString:targetSessionId]) {
                    [window select];   // promote the right window of several
                    [tab select];      // moves visible-tab focus
                    [session select];  // focus the pane (split-pane case)
                    return YES;
                }
            }
        }
    }

    return NO;
}

/*
 * pesterm_reveal_iterm_session_by_tty — same traversal, matching session.tty instead of
 * session.id (see header). For the tmux path: front the iTerm session whose tty equals the
 * attached tmux client's tty. Both sides report the full "/dev/ttysNNN" path; we trim both
 * before comparing to tolerate stray whitespace/newlines.
 */
BOOL pesterm_reveal_iterm_session_by_tty(NSString *tty, NSString *bundleId) {
    if (tty == nil || bundleId == nil) {
        return NO;
    }

    NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *targetTty = [tty stringByTrimmingCharactersInSet:ws];
    if (targetTty.length == 0) {
        return NO;
    }

    iTermBridgeApplication *app =
        (iTermBridgeApplication *)[SBApplication
            applicationWithBundleIdentifier:bundleId];
    if (app == nil) {
        return NO;
    }

    for (iTermBridgeWindow *window in app.windows) {
        for (iTermBridgeTab *tab in window.tabs) {
            for (iTermBridgeSession *session in tab.sessions) {
                NSString *sessionTty = session.tty;
                if (sessionTty != nil &&
                    [[sessionTty stringByTrimmingCharactersInSet:ws] isEqualToString:targetTty]) {
                    [window select];
                    [tab select];
                    [session select];
                    return YES;
                }
            }
        }
    }

    return NO;
}
