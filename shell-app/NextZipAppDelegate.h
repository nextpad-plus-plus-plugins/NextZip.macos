// NextZipAppDelegate — the standalone app's NSApplicationDelegate.
//
// Owns the menu bar and the multi-window lifecycle. Every "Open Archive…" /
// Finder-open spawns a NextZipMainWindowController (one window per archive);
// opening an already-open archive focuses its window instead of duplicating.
// An empty window (disk browser) is opened on a bare launch. Closing the last
// window quits the app.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class NextZipMainWindowController;

@interface NextZipAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>

// Snapshot of the open windows, in creation order.
@property (nonatomic, readonly) NSArray<NextZipMainWindowController*>* windowControllers;

- (IBAction)newWindow:(nullable id)sender;          // ⌘N + Dock menu — empty browse window
- (IBAction)openArchive:(nullable id)sender;        // ⌘O — open panel
- (IBAction)openRecentArchive:(id)sender;           // tag = MRU index
- (IBAction)clearRecentArchives:(nullable id)sender;
- (IBAction)showNextZipHelp:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
