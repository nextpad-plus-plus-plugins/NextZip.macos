#import "NextZipMainWindowController.h"
#import "NextZipController.h"

// Single shared window-frame autosave key. With multiple windows AppKit
// cascades new ones from the saved frame — fine for an archive browser.
static NSString* const kNextZipWindowAutosave = @"NextZip.MainWindow";

static const CGFloat kDefaultW = 900.0, kDefaultH = 640.0;
static const CGFloat kMinW     = 560.0, kMinH     = 380.0;

// The 7-Zip engine is compiled into the app executable, so it can't auto-resolve
// 7z.so "next to the plugin dylib". We bundle 7z.so in Resources and point the
// controller's engine at it.
static NSString* bundledSevenZipSo(void) {
	return [[NSBundle mainBundle] pathForResource:@"7z" ofType:@"so"];
}

@implementation NextZipMainWindowController {
	NextZipController* _controller;
}

- (instancetype)initWithArchivePath:(nullable NSString*)archivePath {
	NSRect content = NSMakeRect(0, 0, kDefaultW, kDefaultH);
	NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
	                 | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
	NSWindow* window = [[NSWindow alloc] initWithContentRect:content
	                                              styleMask:style
	                                                backing:NSBackingStoreBuffered
	                                                  defer:NO];
	window.title              = @"NextZip";
	window.releasedWhenClosed = NO;
	window.minSize            = NSMakeSize(kMinW, kMinH);

	if ((self = [super initWithWindow:window])) {
		window.frameAutosaveName = kNextZipWindowAutosave;
		[window center];
		[window setFrameUsingName:kNextZipWindowAutosave];

		_controller = [[NextZipController alloc] init];
		_controller.host = self;
		_controller.usesGlassToolbars = YES;   // Tahoe Liquid Glass pills (app-only, macOS 26+)
		_controller.sideBySidePanes  = YES;    // Finder-like: FS left, archive right (app-only)
		NSString* so = bundledSevenZipSo();
		if (so.length) [_controller setEnginePath:so];

		// The controller's view IS the window content.
		NSView* panel = [_controller panelView];
		panel.frame = self.window.contentView.bounds;
		panel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		self.window.contentView = panel;

		if (archivePath.length) [self openArchivePath:archivePath];
	}
	return self;
}

- (void)openArchivePath:(NSString*)path {
	// openArchiveAtPath: triggers nextZipRevealPanel below, which syncs the
	// title + boundArchivePath — so we don't duplicate that here.
	[_controller openArchiveAtPath:path];
}

#pragma mark - NextZipHost

- (void)nextZipOpenExtractedFile:(NSString*)displayPath stablePath:(const char*)stablePath {
	(void)stablePath;  // the app has no editor — open in the default macOS app
	if (displayPath.length)
		[[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:displayPath]];
}

- (nullable NSString*)nextZipCurrentFilePath {
	return nil;  // no "active editor tab" concept in the standalone
}

- (void)nextZipRevealPanel {
	// Called whenever an archive is opened (via File▸Open, Finder, or the
	// in-window disk browser). Keep the title + dedup key in sync however it
	// happened.
	NSString* cur = _controller.currentArchivePath;
	if (cur.length) {
		_boundArchivePath = [cur.stringByStandardizingPath copy];
		NSString* base = cur.lastPathComponent;
		self.window.title = base.length ? [NSString stringWithFormat:@"NextZip — %@", base] : @"NextZip";
	}
	[self.window makeKeyAndOrderFront:nil];
}

@end
