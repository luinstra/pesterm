/*
 * iTermBridge.h
 */

#import <AppKit/AppKit.h>
#import <ScriptingBridge/ScriptingBridge.h>


@class iTermBridgeApplication, iTermBridgeWindow, iTermBridgeTab, iTermBridgeSession;

enum iTermBridgeSaveOptions {
	iTermBridgeSaveOptionsYes = 'yes ' /* Save the file. */,
	iTermBridgeSaveOptionsNo = 'no  ' /* Do not save the file. */,
	iTermBridgeSaveOptionsAsk = 'ask ' /* Ask the user whether or not to save the file. */
};
typedef enum iTermBridgeSaveOptions iTermBridgeSaveOptions;

@protocol iTermBridgeGenericMethods

- (void) delete;  // Delete an object.
- (void) duplicateTo:(SBObject *)to withProperties:(NSDictionary *)withProperties;  // Copy object(s) and put the copies at a new location.
- (BOOL) exists;  // Verify if an object exists.
- (void) moveTo:(SBObject *)to;  // Move object(s) to a new location.
- (void) close;  // Close a document.
- (iTermBridgeTab *) createTabWithProfile:(NSString *)withProfile command:(NSString *)command;  // Create a new tab
- (iTermBridgeTab *) createTabWithDefaultProfileCommand:(NSString *)command;  // Create a new tab with the default profile
- (void) writeContentsOfFile:(NSURL *)contentsOfFile text:(NSString *)text newline:(BOOL)newline;  // Send text as though it was typed.
- (void) select;  // Make receiver visible and selected.
- (iTermBridgeSession *) splitVerticallyWithProfile:(NSString *)withProfile command:(NSString *)command;  // Split a session vertically.
- (iTermBridgeSession *) splitVerticallyWithDefaultProfileCommand:(NSString *)command;  // Split a session vertically, using the default profile for the new session
- (iTermBridgeSession *) splitVerticallyWithSameProfileCommand:(NSString *)command;  // Split a session vertically, using the original session's profile for the new session
- (iTermBridgeSession *) splitHorizontallyWithProfile:(NSString *)withProfile command:(NSString *)command;  // Split a session horizontally.
- (iTermBridgeSession *) splitHorizontallyWithDefaultProfileCommand:(NSString *)command;  // Split a session horizontally, using the default profile for the new session
- (iTermBridgeSession *) splitHorizontallyWithSameProfileCommand:(NSString *)command;  // Split a session horizontally, using the original session's profile for the new session
- (NSString *) variableNamed:(NSString *)named;  // Returns the value of a session variable with the given name
- (NSString *) setVariableNamed:(NSString *)named to:(NSString *)to;  // Sets the value of a session variable
- (void) revealHotkeyWindow;  // Reveals a hotkey window. Only to be called on windows that are hotkey windows.
- (void) hideHotkeyWindow;  // Hides a hotkey window. Only to be called on windows that are hotkey windows.
- (void) toggleHotkeyWindow;  // Toggles the visibility of a hotkey window. Only to be called on windows that are hotkey windows.

@end



/*
 * Standard Suite
 */

// The application's top-level scripting object.
@interface iTermBridgeApplication : SBApplication

- (SBElementArray<iTermBridgeWindow *> *) windows;

@property (copy) iTermBridgeWindow *currentWindow;  // The frontmost window
@property (copy, readonly) NSString *name;  // The name of the application.
@property (readonly) BOOL frontmost;  // Is this the frontmost (active) application?
@property (copy, readonly) NSString *version;  // The version of the application.

- (NSString *) requestCookieAndKeyForAppNamed:(NSString *)andKeyForAppNamed;  // Request a Python API cookie
- (iTermBridgeWindow *) createWindowWithProfile:(NSString *)x command:(NSString *)command;  // Create a new window
- (iTermBridgeWindow *) createHotkeyWindowWithProfile:(NSString *)x;  // Create a hotkey window
- (void) launchAPIScriptNamed:(NSString *)x arguments:(NSArray<NSString *> *)arguments;  // Launch API script by name
- (NSString *) invokeAPIExpression:(NSString *)x;  // Invokes an expression, such as a registered function.
- (iTermBridgeWindow *) createWindowWithDefaultProfileCommand:(NSString *)command;  // Create a new window with the default profile

@end

// A window.
@interface iTermBridgeWindow : SBObject <iTermBridgeGenericMethods>

- (SBElementArray<iTermBridgeTab *> *) tabs;

- (NSInteger) id;  // The unique identifier of the session.
@property (copy, readonly) NSString *alternateIdentifier;  // The alternate unique identifier of the session.
@property (copy, readonly) NSString *name;  // The full title of the window.
@property NSInteger index;  // The index of the window, ordered front to back.
@property NSRect bounds;  // The bounding rectangle of the window.
@property (readonly) BOOL closeable;  // Whether the window has a close box.
@property (readonly) BOOL miniaturizable;  // Whether the window can be minimized.
@property BOOL miniaturized;  // Whether the window is currently minimized.
@property (readonly) BOOL resizable;  // Whether the window can be resized.
@property BOOL visible;  // Whether the window is currently visible.
@property (readonly) BOOL zoomable;  // Whether the window can be zoomed.
@property BOOL zoomed;  // Whether the window is currently zoomed.
@property BOOL frontmost;  // Whether the window is currently the frontmost window.
@property (copy) iTermBridgeTab *currentTab;  // The currently selected tab
@property (copy) iTermBridgeSession *currentSession;  // The current session in a window
@property BOOL isHotkeyWindow;  // Whether the window is a hotkey window.
@property (copy) NSString *hotkeyWindowProfile;  // If the window is a hotkey window, this gives the name of the profile that created the window. 
@property NSPoint position;  // The position of the window, relative to the upper left corner of the screen.
@property NSPoint origin;  // The position of the window, relative to the lower left corner of the screen.
@property NSPoint size;  // The width and height of the window
@property NSRect frame;  // The bounding rectangle, relative to the lower left corner of the screen.


@end



/*
 * iTerm2 Suite
 */

// A terminal tab
@interface iTermBridgeTab : SBObject <iTermBridgeGenericMethods>

- (SBElementArray<iTermBridgeSession *> *) sessions;

@property (copy) iTermBridgeSession *currentSession;  // The current session in a tab
@property NSInteger index;  // Index of tab in parent tab view control
@property (copy) NSString *title;


@end

// A terminal session
@interface iTermBridgeSession : SBObject <iTermBridgeGenericMethods>

- (NSString *) id;  // The unique identifier of the session. ScriptingBridge dynamic property.
@property BOOL isProcessing;  // The session has received output recently.
@property BOOL isAtShellPrompt;  // The terminal is at the shell prompt. Requires shell integration.
@property NSInteger columns;
@property NSInteger rows;
@property (copy, readonly) NSString *tty;
@property (copy) NSString *contents;  // The currently visible contents of the session.
@property (copy, readonly) NSString *text;  // The currently visible contents of the session.
@property (copy) NSString *colorPreset;
@property (copy) NSColor *backgroundColor;
@property (copy) NSColor *boldColor;
@property (copy) NSColor *cursorColor;
@property (copy) NSColor *cursorTextColor;
@property (copy) NSColor *foregroundColor;
@property (copy) NSColor *selectedTextColor;
@property (copy) NSColor *selectionColor;
@property (copy) NSColor *ANSIBlackColor;
@property (copy) NSColor *ANSIRedColor;
@property (copy) NSColor *ANSIGreenColor;
@property (copy) NSColor *ANSIYellowColor;
@property (copy) NSColor *ANSIBlueColor;
@property (copy) NSColor *ANSIMagentaColor;
@property (copy) NSColor *ANSICyanColor;
@property (copy) NSColor *ANSIWhiteColor;
@property (copy) NSColor *ANSIBrightBlackColor;
@property (copy) NSColor *ANSIBrightRedColor;
@property (copy) NSColor *ANSIBrightGreenColor;
@property (copy) NSColor *ANSIBrightYellowColor;
@property (copy) NSColor *ANSIBrightBlueColor;
@property (copy) NSColor *ANSIBrightMagentaColor;
@property (copy) NSColor *ANSIBrightCyanColor;
@property (copy) NSColor *ANSIBrightWhiteColor;
@property (copy) NSColor *underlineColor;
@property BOOL useUnderlineColor;  // Whether the use a dedicated color for underlining.
@property (copy) NSString *backgroundImage;
@property (copy) NSString *name;
@property double transparency;
@property (copy, readonly) NSString *uniqueID;
@property (copy, readonly) NSString *profileName;  // The session's profile name
@property (copy) NSString *answerbackString;  // ENQ Answerback string


@end


/*
 * Reveal helper — implemented in Objective-C to avoid the ScriptingBridge-in-Swift
 * downcast problem. SBApplication(bundleIdentifier:) returns a private dynamic
 * subclass, so Swift's `as? iTermBridgeApplication` (a real is-a check) fails even
 * though Objective-C message dispatch works fine. Doing the whole traversal in ObjC
 * (which never does an is-a check) sidesteps the issue entirely.
 *
 * `bundleId` is the terminal's bundle identifier (the single source of truth lives in
 * the Swift revealer; it is passed in rather than hardcoded here so the constant is not
 * duplicated). Returns YES if a session whose `id` equals targetSessionId was found and
 * window/tab/session were selected; NO if no match (or app/bundleId unavailable). The
 * caller still treats iTerm as fronted regardless (front is done separately in AppKit).
 */
BOOL pesterm_reveal_iterm_session(NSString *targetSessionId, NSString *bundleId);

/*
 * Like pesterm_reveal_iterm_session, but matches the session by its TTY
 * (`iTermBridgeSession.tty`, e.g. "/dev/ttys003") instead of its `id`. Used by the tmux
 * revealer: under tmux there is no iTerm session GUID to match, so we resolve the attached
 * tmux client's tty and front the iTerm session whose tty equals it. Comparison is on the
 * whitespace-trimmed tty. Returns YES if a session matched and window/tab/session were
 * selected; NO otherwise (caller falls back to fronting the app only).
 */
BOOL pesterm_reveal_iterm_session_by_tty(NSString *tty, NSString *bundleId);

