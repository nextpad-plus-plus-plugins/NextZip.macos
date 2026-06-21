// NextZipMainWindowController — owns one standalone-app window and the
// NextZipController (the shared archive-manager view + logic) that fills it.
//
// One controller = one window = one archive. The app may have many alive at
// once (one per open archive). This window controller is itself the
// NextZipController's host bridge: it opens extracted files in the default
// macOS app and brings its window forward.

#import <Cocoa/Cocoa.h>
#import "NextZipHost.h"

NS_ASSUME_NONNULL_BEGIN

@interface NextZipMainWindowController : NSWindowController <NextZipHost>

// Standardized path of the archive currently shown in this window, or nil for
// an empty (browse-only) window. Lets the app dedup "open the same archive".
@property (nonatomic, readonly, copy, nullable) NSString* boundArchivePath;

// Designated initializer. Pass an archive path to open it immediately; pass nil
// for an empty window where the user browses the disk pane and clicks an archive.
- (instancetype)initWithArchivePath:(nullable NSString*)archivePath NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder*)c NS_UNAVAILABLE;
- (instancetype)initWithWindow:(nullable NSWindow*)window NS_UNAVAILABLE;
- (instancetype)initWithWindowNibName:(NSNibName)name NS_UNAVAILABLE;

// Load an archive into this window (used by File ▸ Open / Finder open).
- (void)openArchivePath:(NSString*)path;

@end

NS_ASSUME_NONNULL_END
