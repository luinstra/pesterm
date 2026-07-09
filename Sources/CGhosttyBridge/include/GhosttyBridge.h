/*
 * GhosttyBridge.h
 *
 * sdp-generated Ghostty ScriptingBridge classes (from Ghostty 1.3.1's sdef; see
 * docs/ghostty-sdef-findings.md) with the two pesterm_ghostty_* reveal helpers
 * appended at the end — the same one-header vendored layout as CITermBridge.
 * Regenerate the GENERATED portion with scripts/verify-ghostty-sdef.sh, which
 * preserves everything after the "pesterm additions" marker below.
 *
 * REGEN NOTE: the pragma right below this comment is ABOVE the marker, so a
 * regeneration drops it — re-apply it (a fresh build warns loudly if missing).
 */

// The pesterm_ghostty_focused_terminal_cwd `_Nullable` return is the only nullability
// annotation in this file, which flips clang's completeness audit ON for every generated
// pointer (-Wnullability-completeness). Silenced in the header itself so EVERY parse sees
// it — the C-target compile AND Swift's ClangImporter module build (Package.swift
// cSettings do not reach the importer; some toolchains warn there).
#pragma clang diagnostic ignored "-Wnullability-completeness"

#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>


@class GhosttyApplication, GhosttyWindow, GhosttyTab, GhosttyTerminal;

// Direction for a new split.
enum GhosttySplitDirection {
	GhosttySplitDirectionRight = 'GSrt' /* Split to the right. */,
	GhosttySplitDirectionLeft = 'GSlf' /* Split to the left. */,
	GhosttySplitDirectionDown = 'GSdn' /* Split downward. */,
	GhosttySplitDirectionUp = 'GSup' /* Split upward. */
};
typedef enum GhosttySplitDirection GhosttySplitDirection;

// Whether an input is pressed or released.
enum GhosttyInputAction {
	GhosttyInputActionPress = 'GIpr' /* Press. */,
	GhosttyInputActionRelease = 'GIrl' /* Release. */
};
typedef enum GhosttyInputAction GhosttyInputAction;

// A mouse button.
enum GhosttyMouseButton {
	GhosttyMouseButtonLeftButton = 'GMlf' /* Left mouse button. */,
	GhosttyMouseButtonRightButton = 'GMrt' /* Right mouse button. */,
	GhosttyMouseButtonMiddleButton = 'GMmd' /* Middle mouse button. */
};
typedef enum GhosttyMouseButton GhosttyMouseButton;

// Momentum phase for inertial scrolling.
enum GhosttyScrollMomentum {
	GhosttyScrollMomentumNone = 'SMno' /* No momentum. */,
	GhosttyScrollMomentumBegan = 'SMbg' /* Momentum began. */,
	GhosttyScrollMomentumChanged = 'SMch' /* Momentum changed. */,
	GhosttyScrollMomentumEnded = 'SMen' /* Momentum ended. */,
	GhosttyScrollMomentumCancelled = 'SMcn' /* Momentum cancelled. */,
	GhosttyScrollMomentumMayBegin = 'SMmb' /* Momentum may begin. */,
	GhosttyScrollMomentumStationary = 'SMst' /* Stationary. */
};
typedef enum GhosttyScrollMomentum GhosttyScrollMomentum;

@protocol GhosttyGenericMethods

- (GhosttyTerminal *) splitDirection:(GhosttySplitDirection)direction withConfiguration:(NSDictionary *)withConfiguration;  // Split a terminal in the given direction.
- (void) focus;  // Focus a terminal, bringing its window to the front.
- (void) close;  // Close a terminal.
- (void) activateWindow;  // Activate a Ghostty window, bringing it to the front.
- (void) selectTab;  // Select a tab in its window.
- (void) closeTab;  // Close a tab.
- (void) closeWindow;  // Close a window.

@end



/*
 * Ghostty Suite
 */

// The Ghostty application.
@interface GhosttyApplication : SBApplication

- (SBElementArray<GhosttyWindow *> *) windows;
- (SBElementArray<GhosttyTerminal *> *) terminals;

@property (copy, readonly) NSString *name;  // The name of the application.
@property (readonly) BOOL frontmost;  // Is this the active application?
@property (copy, readonly) GhosttyWindow *frontWindow;  // The frontmost Ghostty window.
@property (copy, readonly) NSString *version;  // The version number of the application.

- (BOOL) performAction:(NSString *)x on:(GhosttyTerminal *)on;  // Perform a Ghostty action string on a terminal.
- (NSDictionary *) newSurfaceConfigurationFrom:(NSDictionary *)from NS_RETURNS_NOT_RETAINED;  // Create a reusable surface configuration object.
- (GhosttyWindow *) newWindowWithConfiguration:(NSDictionary *)withConfiguration NS_RETURNS_NOT_RETAINED;  // Create a new Ghostty window.
- (GhosttyTab *) newTabIn:(GhosttyWindow *)in_ withConfiguration:(NSDictionary *)withConfiguration NS_RETURNS_NOT_RETAINED;  // Create a new Ghostty tab.
- (void) inputText:(NSString *)x to:(GhosttyTerminal *)to;  // Input text to a terminal as if it was pasted.
- (void) sendKey:(NSString *)x action:(GhosttyInputAction)action modifiers:(NSString *)modifiers to:(GhosttyTerminal *)to;  // Send a keyboard event to a terminal.
- (void) sendMouseButton:(GhosttyMouseButton)x action:(GhosttyInputAction)action modifiers:(NSString *)modifiers to:(GhosttyTerminal *)to;  // Send a mouse button event to a terminal.
- (void) sendMousePositionX:(double)x y:(double)y modifiers:(NSString *)modifiers to:(GhosttyTerminal *)to;  // Send a mouse position event to a terminal.
- (void) sendMouseScrollX:(double)x y:(double)y precision:(BOOL)precision momentum:(GhosttyScrollMomentum)momentum to:(GhosttyTerminal *)to;  // Send a mouse scroll event to a terminal.
- (BOOL) exists:(id)x;  // Verify that an object exists.
- (void) quit;  // Quit the application.

@end

// A Ghostty window containing one or more tabs.
@interface GhosttyWindow : SBObject <GhosttyGenericMethods>

- (SBElementArray<GhosttyTab *> *) tabs;
- (SBElementArray<GhosttyTerminal *> *) terminals;

- (NSString *) id;  // Stable ID for this window.
@property (copy, readonly) NSString *name;  // The title of the window.
@property (copy, readonly) GhosttyTab *selectedTab;  // The selected tab in this window.


@end

// A tab within a Ghostty window.
@interface GhosttyTab : SBObject <GhosttyGenericMethods>

- (SBElementArray<GhosttyTerminal *> *) terminals;

- (NSString *) id;  // Stable ID for this tab.
@property (copy, readonly) NSString *name;  // The title of the tab.
@property (readonly) NSInteger index;  // 1-based index of this tab in its window.
@property (readonly) BOOL selected;  // Whether this tab is selected in its window.
@property (copy, readonly) GhosttyTerminal *focusedTerminal;  // The currently focused terminal surface in this tab.


@end

// An individual terminal surface.
@interface GhosttyTerminal : SBObject <GhosttyGenericMethods>

- (NSString *) id;  // Stable ID for this terminal surface.
@property (copy, readonly) NSString *name;  // Current terminal title.
@property (copy, readonly) NSString *workingDirectory;  // Current working directory for the terminal process.


@end


/*
 * ==== pesterm additions (hand-written — everything below this marker survives
 * ==== header regeneration; see scripts/verify-ghostty-sdef.sh)
 *
 * Reveal helpers — implemented in Objective-C to avoid the ScriptingBridge-in-Swift
 * downcast problem: SBApplication(bundleIdentifier:) returns a private dynamic
 * subclass, so Swift's `as? GhosttyApplication` (a real is-a check) fails even
 * though the object responds to every message. Objective-C never does an is-a check
 * on the cast, so the traversal works there (same trap as iTermBridge.h).
 *
 * `bundleID` is passed in from the Swift revealer (single source of truth for the
 * constant). No decision logic lives here — listing and focusing only; the
 * one-match-or-fallback rule is the pure Swift GhosttyEnv's job.
 */

/*
 * Traverse windows -> tabs -> terminals and return one entry per terminal:
 *   { @"terminalId": NSString, @"windowId": NSString, @"tabId": NSString, @"cwd": NSString }
 * All id values are stringified at this boundary (the sdef declares them text, but a
 * future sdef changing the type must not leak non-strings into Swift); `cwd` is the raw
 * `working directory` string, or @"" when absent. Returns an EMPTY array on any failure
 * (app not scriptable, Automation grant missing, `macos-applescript = false`) — the
 * caller cannot distinguish those causes here and must not try.
 */
NSArray<NSDictionary *> * pesterm_ghostty_list_terminals(NSString *bundleID);

/*
 * Re-find the terminal by walking to the window/tab by id, then the terminal by id
 * within it, and front it with the belt-and-braces sequence `activate window` +
 * `select tab` + `focus` (focus-alone semantics are unverified; see
 * docs/ghostty-sdef-findings.md deferred check 2). Returns NO if any component no
 * longer exists (window/tab/terminal closed between list and focus).
 */
BOOL pesterm_ghostty_focus_terminal(NSString *windowId, NSString *tabId,
                                    NSString *terminalId, NSString *bundleID);

/*
 * Focus-probe helper (focus-aware notification deferral): the working directory of the
 * FOCUSED terminal surface — `app.frontWindow.selectedTab.focusedTerminal.
 * workingDirectory` — or nil on ANY failure (app not scriptable, grant missing, no
 * windows, no cwd reported yet). READ-ONLY: no activate/select/focus calls — a probe
 * must never move focus. Same no-decision-logic rule as the helpers above: the pure
 * Swift GhosttyEnv compares the returned cwd.
 */
NSString * _Nullable pesterm_ghostty_focused_terminal_cwd(NSString *bundleID);
