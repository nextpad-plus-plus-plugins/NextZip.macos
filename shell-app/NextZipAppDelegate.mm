#import "NextZipAppDelegate.h"
#import "NextZipMainWindowController.h"
#import "NextZipMenuBuilder.h"

// MRU of recently-opened archive paths.
static NSString* const kRecentArchivesKey = @"NextZipRecentArchives";
static const NSUInteger kMaxRecent = 12;
static NSString* const kHelpURL = @"https://github.com/nextpad-plus-plus-plugins/NextZip.macos";

@implementation NextZipAppDelegate {
	NSMutableArray<NextZipMainWindowController*>* _wcs;
}

- (instancetype)init {
	if ((self = [super init])) { _wcs = [NSMutableArray new]; }
	return self;
}

#pragma mark - Lifecycle

- (void)applicationWillFinishLaunching:(NSNotification*)note {
	[NSApp setMainMenu:[NextZipMenuBuilder buildMainMenuForDelegate:self]];
}

- (void)applicationDidFinishLaunching:(NSNotification*)note {
	// If Finder/open didn't already hand us an archive (which would have
	// created a window in application:openURLs:), open one empty browse window.
	// Deferred a turn so a same-launch openURLs: wins the race.
	dispatch_async(dispatch_get_main_queue(), ^{
		if (self->_wcs.count == 0) [self _openWindowForArchive:nil];
	});
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender { return YES; }

- (BOOL)applicationShouldOpenUntitledFile:(NSApplication*)sender {
	return NO;  // didFinishLaunching: owns startup-time window creation
}

- (void)application:(NSApplication*)application openURLs:(NSArray<NSURL*>*)urls {
	for (NSURL* url in urls) {
		if (!url.isFileURL) continue;
		[self _openOrFocusArchive:url.path];
	}
}

#pragma mark - Window management

- (NSArray<NextZipMainWindowController*>*)windowControllers { return [_wcs copy]; }

- (NextZipMainWindowController*)_openWindowForArchive:(nullable NSString*)path {
	NextZipMainWindowController* wc = [[NextZipMainWindowController alloc] initWithArchivePath:path];
	[_wcs addObject:wc];
	[self _registerCloseHandlerFor:wc];
	[wc showWindow:self];
	[wc.window makeKeyAndOrderFront:nil];
	if (path.length) [self _noteRecentArchive:path];
	return wc;
}

- (NextZipMainWindowController*)_openOrFocusArchive:(NSString*)path {
	NSString* std = path.stringByStandardizingPath;
	for (NextZipMainWindowController* wc in _wcs) {
		if (wc.boundArchivePath.length && [wc.boundArchivePath isEqualToString:std]) {
			if (wc.window.isMiniaturized) [wc.window deminiaturize:nil];
			[wc.window makeKeyAndOrderFront:nil];
			[self _noteRecentArchive:path];
			return wc;
		}
	}
	return [self _openWindowForArchive:path];
}

// Self-unregistering close observer: drop our strong ref so the WC (and its
// controller + engine) deallocs, and so terminate-after-last-window fires.
- (void)_registerCloseHandlerFor:(NextZipMainWindowController*)wc {
	__weak typeof(self) weakSelf = self;
	__weak NextZipMainWindowController* weakWC = wc;
	__block id token = nil;
	token = [[NSNotificationCenter defaultCenter]
		addObserverForName:NSWindowWillCloseNotification
		            object:wc.window
		             queue:[NSOperationQueue mainQueue]
		        usingBlock:^(NSNotification* n) {
		typeof(self) strongSelf = weakSelf;
		NextZipMainWindowController* strongWC = weakWC;
		if (strongSelf && strongWC) [strongSelf->_wcs removeObject:strongWC];
		if (token) [[NSNotificationCenter defaultCenter] removeObserver:token];
	}];
}

#pragma mark - Actions

- (IBAction)newWindow:(nullable id)sender { [self _openWindowForArchive:nil]; }

- (IBAction)openArchive:(nullable id)sender {
	NSOpenPanel* p = [NSOpenPanel openPanel];
	p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = YES;
	p.message = @"Choose an archive to open.";
	// No type filter: the engine content-detects every format 7-Zip reads.
	NSWindow* parent = NSApp.keyWindow ?: _wcs.firstObject.window;
	void (^handle)(NSModalResponse) = ^(NSModalResponse rc) {
		if (rc != NSModalResponseOK) return;
		for (NSURL* url in p.URLs) [self _openOrFocusArchive:url.path];
	};
	if (parent) [p beginSheetModalForWindow:parent completionHandler:handle];
	else        handle([p runModal]);
}

- (IBAction)openRecentArchive:(id)sender {
	NSArray* mru = [[NSUserDefaults standardUserDefaults] arrayForKey:kRecentArchivesKey] ?: @[];
	NSInteger idx = [(NSMenuItem*)sender tag];
	if (idx < 0 || (NSUInteger)idx >= mru.count) return;
	NSString* path = mru[idx];
	if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
		[self _openOrFocusArchive:path];
	} else {
		// Stale entry → drop it.
		NSMutableArray* m = [mru mutableCopy];
		[m removeObjectAtIndex:(NSUInteger)idx];
		[[NSUserDefaults standardUserDefaults] setObject:m forKey:kRecentArchivesKey];
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = @"File not found";
		a.informativeText = path;
		[a addButtonWithTitle:@"OK"]; [a runModal];
	}
}

- (IBAction)clearRecentArchives:(nullable id)sender {
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:kRecentArchivesKey];
}

- (IBAction)showNextZipHelp:(nullable id)sender {
	NSURL* url = [NSURL URLWithString:kHelpURL];
	if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

#pragma mark - Dock menu

- (NSMenu*)applicationDockMenu:(NSApplication*)sender {
	NSMenu* menu = [[NSMenu alloc] init];
	NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:@"New Window"
	                                            action:@selector(newWindow:) keyEquivalent:@""];
	it.target = self; [menu addItem:it];
	return menu;
}

#pragma mark - Open Recent (NSMenuDelegate)

- (void)menuNeedsUpdate:(NSMenu*)menu {
	if (![menu.title isEqualToString:@"Open Recent"]) return;
	[menu removeAllItems];
	NSArray* mru = [[NSUserDefaults standardUserDefaults] arrayForKey:kRecentArchivesKey] ?: @[];
	if (mru.count == 0) {
		NSMenuItem* empty = [[NSMenuItem alloc] initWithTitle:@"(no recent archives)" action:nil keyEquivalent:@""];
		empty.enabled = NO; [menu addItem:empty];
		return;
	}
	for (NSUInteger i = 0; i < mru.count; i++) {
		NSString* path = mru[i];
		if (![path isKindOfClass:[NSString class]]) continue;
		NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:path.lastPathComponent
		                                            action:@selector(openRecentArchive:) keyEquivalent:@""];
		it.target = self; it.tag = (NSInteger)i; it.toolTip = path;
		[menu addItem:it];
	}
	[menu addItem:[NSMenuItem separatorItem]];
	NSMenuItem* clear = [[NSMenuItem alloc] initWithTitle:@"Clear Menu"
	                                              action:@selector(clearRecentArchives:) keyEquivalent:@""];
	clear.target = self; [menu addItem:clear];
}

#pragma mark - MRU helper

- (void)_noteRecentArchive:(NSString*)path {
	if (!path.length) return;
	NSUserDefaults* def = [NSUserDefaults standardUserDefaults];
	NSMutableArray* mru = [([def arrayForKey:kRecentArchivesKey] ?: @[]) mutableCopy];
	[mru removeObject:path];
	[mru insertObject:path atIndex:0];
	while (mru.count > kMaxRecent) [mru removeLastObject];
	[def setObject:mru forKey:kRecentArchivesKey];
}

@end
