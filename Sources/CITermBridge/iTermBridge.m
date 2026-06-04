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

@implementation iTermBridgeApplication
@end

@implementation iTermBridgeWindow
@end

@implementation iTermBridgeTab
@end

@implementation iTermBridgeSession
@end

/*
 * pesterm_reveal_iterm_session — the actual reveal traversal, done in Objective-C.
 *
 * The hierarchy is one-directional (a session has no back-pointer to its tab, a tab
 * none to its window), so we retain the enclosing loop variables and select
 * window -> tab -> session on a match. The first Apple Event sent here is what
 * triggers the Automation (TCC) prompt on first run — that is expected and correct.
 */
BOOL pesterm_reveal_iterm_session(NSString *targetSessionId) {
    if (targetSessionId == nil) {
        return NO;
    }

    iTermBridgeApplication *app =
        (iTermBridgeApplication *)[SBApplication
            applicationWithBundleIdentifier:@"com.googlecode.iterm2"];
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
