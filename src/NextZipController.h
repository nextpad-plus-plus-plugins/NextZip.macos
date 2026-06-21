/*
 * NextZipController.h — the NextZip archive-manager window controller.
 * Scaffold: opens an archive via NextZipEngine and lists its entries in a
 * sortable NSTableView (the seed of the 7-Zip-File-Manager-style UI). Toolbar,
 * breadcrumb navigation, descend-into-folders/nested-archives, extract, create,
 * and drag-out come next.
 *
 * NextZip (Nextpad++ archive plugin) 2026 (GPL).
 */
#import <Cocoa/Cocoa.h>
#import "NextZipHost.h"

@interface NextZipController : NSObject

// The host bridge (plugin or app). Weak — the host owns the controller.
@property (nonatomic, weak) id<NextZipHost> host;

// When YES, each toolbar icon is wrapped in its own Tahoe Liquid Glass capsule
// (NSGlassEffectView, with a grey hover tint) on macOS 26+; older macOS falls
// back to plain textured buttons. Both shells (standalone app and plugin) set
// this so their toolbars look identical. Must be set before -panelView is first
// called (the toolbar is built once and cached).
@property (nonatomic) BOOL usesGlassToolbars;

// The archive-manager view (filesystem browser on top, archive contents
// below). Built lazily on first access. The plugin registers it as a dock
// panel; the app puts it in a window's contentView.
- (NSView*)panelView;

// Point the engine at a specific 7z.so. The app bundles 7z.so in its Resources
// and calls this; the plugin auto-resolves it next to its dylib and needn't.
- (void)setEnginePath:(NSString*)sevenZipSoPath;

// The outermost real archive file currently shown (for the app's window title /
// dedup), or nil if none is open yet.
@property (nonatomic, readonly, nullable) NSString* currentArchivePath;

- (void)showOpenPanel;                 // "Open Archive…" menu command
- (void)openArchiveAtPath:(NSString*)path;
- (void)openCurrentEditorFile;         // open the host's current file as an archive
- (void)handleFileSaved:(NSString*)path; // write a temp we extracted back into its archive
- (void)showAbout;
@end
