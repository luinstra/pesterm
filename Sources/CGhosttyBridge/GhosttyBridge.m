/*
 * GhosttyBridge.m — empty @implementation blocks for the sdp-generated ScriptingBridge
 * classes, plus the two pesterm_ghostty_* reveal helpers.
 *
 * Why the empty blocks exist: sdp generates only an interface header. The classes are
 * dynamically vivified by ScriptingBridge at runtime, but any compile-time reference to
 * a concrete generated class emits a link-time class-symbol reference
 * (_OBJC_CLASS_$_GhosttyApplication); without an @implementation those symbols do not
 * exist and linking fails. Same shape as CITermBridge/iTermBridge.m.
 */

#import "include/GhosttyBridge.h"

// INTENTIONALLY empty (see file header): every method is provided dynamically by
// ScriptingBridge at runtime. -Wincomplete-implementation and -Wprotocol flag exactly
// that "declared but not implemented" shape, so silence both for just these stubs.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"

@implementation GhosttyApplication
@end

@implementation GhosttyWindow
@end

@implementation GhosttyTab
@end

@implementation GhosttyTerminal
@end

#pragma clang diagnostic pop

/*
 * Stringify an id value read off the bridge. The sdef declares all three ids as text,
 * so this is normally pass-through; `description` defends against a future sdef
 * changing the type (the Swift layer must only ever see String). nil -> nil.
 */
static NSString *pesterm_ghostty_string(id value) {
    if (value == nil) {
        return nil;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return (NSString *)value;
    }
    return [value description];
}

NSArray<NSDictionary *> * pesterm_ghostty_list_terminals(NSString *bundleID) {
    if (bundleID == nil) {
        return @[];
    }

    GhosttyApplication *app =
        (GhosttyApplication *)[SBApplication applicationWithBundleIdentifier:bundleID];
    if (app == nil) {
        return @[];
    }

    // An ungranted Automation (TCC) state or `macos-applescript = false` makes this
    // traversal see zero windows — indistinguishable from "no windows open" here, by
    // design. nil-messaging keeps every branch crash-free; entries missing any id are
    // skipped (they could never be re-found for focusing).
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    for (GhosttyWindow *window in app.windows) {
        NSString *windowId = pesterm_ghostty_string([window id]);
        if (windowId == nil) {
            continue;
        }
        for (GhosttyTab *tab in window.tabs) {
            NSString *tabId = pesterm_ghostty_string([tab id]);
            if (tabId == nil) {
                continue;
            }
            for (GhosttyTerminal *terminal in tab.terminals) {
                NSString *terminalId = pesterm_ghostty_string([terminal id]);
                if (terminalId == nil) {
                    continue;
                }
                NSString *cwd = pesterm_ghostty_string(terminal.workingDirectory);
                [entries addObject:@{
                    @"terminalId": terminalId,
                    @"windowId": windowId,
                    @"tabId": tabId,
                    @"cwd": cwd ?: @"",
                }];
            }
        }
    }
    return entries;
}

BOOL pesterm_ghostty_focus_terminal(NSString *windowId, NSString *tabId,
                                    NSString *terminalId, NSString *bundleID) {
    if (windowId == nil || tabId == nil || terminalId == nil || bundleID == nil) {
        return NO;
    }

    GhosttyApplication *app =
        (GhosttyApplication *)[SBApplication applicationWithBundleIdentifier:bundleID];
    if (app == nil) {
        return NO;
    }

    for (GhosttyWindow *window in app.windows) {
        NSString *wid = pesterm_ghostty_string([window id]);
        if (wid == nil || ![wid isEqualToString:windowId]) {
            continue;
        }
        for (GhosttyTab *tab in window.tabs) {
            NSString *tid = pesterm_ghostty_string([tab id]);
            if (tid == nil || ![tid isEqualToString:tabId]) {
                continue;
            }
            for (GhosttyTerminal *terminal in tab.terminals) {
                NSString *sid = pesterm_ghostty_string([terminal id]);
                if (sid != nil && [sid isEqualToString:terminalId]) {
                    // Belt-and-braces: focus is documented window-fronting, but whether
                    // it also selects a background tab is unverified (findings doc,
                    // deferred check 2) — send all three.
                    [window activateWindow];
                    [tab selectTab];
                    [terminal focus];
                    return YES;
                }
            }
        }
    }

    return NO;
}
