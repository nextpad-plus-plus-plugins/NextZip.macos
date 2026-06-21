/*
 * NextZipHost.h — the tiny host abstraction that lets ONE NextZipController
 * (the shared archive-manager view + logic) serve both the Nextpad++ plugin
 * and the standalone NextZip.app, from a single codebase.
 *
 * The controller never talks to a host directly; it calls through this
 * protocol. Two implementations exist:
 *   - plugin shell (NextZipPlugin.mm): forwards to Nextpad++ via _sendMessage
 *     (NPPM_DOOPEN to open in the editor, NPPM_GETFULLCURRENTPATH, the dock
 *     panel register/show/hide).
 *   - app shell (NextZipAppDelegate): opens extracted files in the default
 *     macOS application and brings the hosting window to the front.
 *
 * NextZip 2026 (GPL).
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol NextZipHost <NSObject>

// Open a file the controller just extracted from the archive to a temp path.
//   displayPath — the temp file's NSString path (the app opens THIS via
//                 NSWorkspace).
//   stablePath  — a C-string that stays valid for the controller's lifetime
//                 (it points into the controller's opened-temps map). The
//                 plugin must pass THIS to NPPM_DOOPEN, which dereferences it
//                 on a later runloop turn; an autoreleased -UTF8String buffer
//                 would already be freed by then ("file name is invalid").
- (void)nextZipOpenExtractedFile:(NSString *)displayPath stablePath:(const char *)stablePath;

// The path to treat as "the current file" for "Open Current File as Archive".
// Plugin: the active editor tab. App: nil (no editor → caller falls back to an
// open panel).
- (nullable NSString *)nextZipCurrentFilePath;

// Ensure the archive-manager panel is visible and frontmost (called right after
// an archive is opened). Plugin: register if needed + NPPM_DMM_SHOWPANEL the
// dock panel. App: bring the hosting window to the front.
- (void)nextZipRevealPanel;

@end

NS_ASSUME_NONNULL_END
