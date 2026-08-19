#import "NextZipAppDelegate.h"
#import "NextZipMainWindowController.h"
#import "NextZipMenuBuilder.h"
#import "NextZipDialogs.h"
#include "SevenZipEngine.h"

// MRU of recently-opened archive paths.
static NSString* const kRecentArchivesKey = @"NextZipRecentArchives";
static const NSUInteger kMaxRecent = 12;
static NSString* const kHelpURL = @"https://github.com/nextpad-plus-plus-plugins/NextZip.macos";

// The bundled 7-Zip engine (Contents/Resources/7z.so).
static NSString* bundledSevenZipSo(void) { return [[NSBundle mainBundle] pathForResource:@"7z" ofType:@"so"]; }

@implementation NextZipAppDelegate {
	NSMutableArray<NextZipMainWindowController*>* _wcs;
	BOOL _serviceInvoked;   // a Finder Service ran → don't also pop an empty window on cold start
}

- (instancetype)init {
	if ((self = [super init])) { _wcs = [NSMutableArray new]; }
	return self;
}

#pragma mark - Lifecycle

- (void)applicationWillFinishLaunching:(NSNotification*)note {
	[NSApp setMainMenu:[NextZipMenuBuilder buildMainMenuForDelegate:self]];
	[NSApp setServicesProvider:self];   // Finder right-click → Services (see NSServices in Info.plist)
}

- (void)applicationDidFinishLaunching:(NSNotification*)note {
	// If Finder/open didn't already hand us an archive (which would have
	// created a window in application:openURLs:), open one empty browse window —
	// unless a Finder Service cold-started us (then just run the service).
	dispatch_async(dispatch_get_main_queue(), ^{
		if (self->_wcs.count == 0 && !self->_serviceInvoked) [self _openWindowForArchive:nil];
	});
}

#pragma mark - Finder Services (NSServices)

- (void)nzAddToArchive:(NSPasteboard*)pboard userData:(NSString*)userData error:(NSString**)error {
	[self _serviceCompress:[self _filePathsFromPasteboard:pboard] thenEmail:NO];
}

- (void)nzCompressAndEmail:(NSPasteboard*)pboard userData:(NSString*)userData error:(NSString**)error {
	[self _serviceCompress:[self _filePathsFromPasteboard:pboard] thenEmail:YES];
}

- (NSArray<NSString*>*)_filePathsFromPasteboard:(NSPasteboard*)pboard {
	_serviceInvoked = YES;
	NSMutableArray<NSString*>* paths = [NSMutableArray array];
	for (NSURL* u in [pboard readObjectsForClasses:@[NSURL.class]
	                   options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}])
		if (u.isFileURL && u.path.length) [paths addObject:u.path];
	if (paths.count == 0) {                                   // legacy Finder fallback
		id names = [pboard propertyListForType:NSFilenamesPboardType];
		if ([names isKindOfClass:[NSArray class]])
			for (id p in (NSArray*)names) if ([p isKindOfClass:[NSString class]] && [p length]) [paths addObject:p];
	}
	return paths;
}

// Run the shared Add-to-Archive dialog for the Finder selection, compress with a
// fresh engine, then reveal the result in Finder — or attach it to a new email.
- (void)_serviceCompress:(NSArray<NSString*>*)paths thenEmail:(BOOL)email {
	if (paths.count == 0) return;
	[NSApp activateIgnoringOtherApps:YES];

	NZAddOptions* o = [NextZipDialogs runAddForInputs:paths];
	if (!o || o.archivePath.length == 0) return;             // cancelled
	if ([[NSFileManager defaultManager] fileExistsAtPath:o.archivePath]) {
		[self _serviceAlert:@"Archive already exists"
		               info:[NSString stringWithFormat:@"%@\n\n(Adding into an existing archive isn't supported here.)", o.archivePath]];
		return;
	}

	NextZipEngine eng;
	NSString* so = bundledSevenZipSo();
	if (so.length) eng.setEnginePath(so.UTF8String);
	NextZipEngine::CompressOptions opt;
	opt.format        = o.format.UTF8String;
	opt.level         = o.level;
	opt.method        = o.method.length        ? o.method.UTF8String        : "";
	opt.dict          = o.dict;
	opt.wordSize      = o.wordSize;
	opt.solid         = o.solid.length         ? o.solid.UTF8String         : "";
	opt.threads       = o.threads;
	opt.memusePercent = o.memusePercent.length ? o.memusePercent.UTF8String : "";
	opt.password      = o.password.length      ? o.password.UTF8String      : "";
	opt.encMethod     = o.encMethod.length     ? o.encMethod.UTF8String     : "";
	opt.encryptNames  = o.encryptNames;
	opt.pathMode      = o.pathMode;
	opt.deleteAfter   = o.deleteAfter;
	opt.extraParams   = o.extraParams.length   ? o.extraParams.UTF8String   : "";
	std::vector<std::string> ins;
	for (NSString* p in paths) ins.push_back(p.UTF8String);

	if (!eng.compress(o.archivePath.UTF8String, opt, ins)) {
		[self _serviceAlert:@"Could not create archive" info:[NSString stringWithUTF8String:eng.error().c_str()]];
		return;
	}
	NSURL* arcURL = [NSURL fileURLWithPath:o.archivePath];
	if (!email) {
		[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[arcURL]];   // reveal in Finder
		return;
	}
	[self _emailArchiveAtPath:o.archivePath];
}

// Open a new message in the user's DEFAULT mail app with the archive attached.
// Scripts the default app directly (reliable + actually attaches), with the
// system email share service and a reveal-and-mailto fallback.
- (void)_emailArchiveAtPath:(NSString*)path {
	NSURL* arcURL  = [NSURL fileURLWithPath:path];
	NSURL* mailApp = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:[NSURL URLWithString:@"mailto:"]];
	NSString* bid  = [NSBundle bundleWithURL:mailApp].bundleIdentifier.lowercaseString;
	NSString* esc  = [[path stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
	                   stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

	NSString* script = nil;
	if ([bid isEqualToString:@"com.apple.mail"]) {
		script = [NSString stringWithFormat:
			@"tell application \"Mail\"\n"
			 "activate\n"
			 "set m to make new outgoing message with properties {visible:true}\n"
			 "tell content of m to make new attachment with properties {file name:(POSIX file \"%@\")} at after the last paragraph\n"
			 "end tell", esc];
	} else if ([bid hasPrefix:@"com.microsoft.outlook"]) {
		script = [NSString stringWithFormat:
			@"tell application \"Microsoft Outlook\"\n"
			 "activate\n"
			 "set m to make new outgoing message\n"
			 "make new attachment at m with properties {file:(POSIX file \"%@\")}\n"
			 "open m\n"
			 "end tell", esc];
	}
	if (script) {
		NSDictionary* err = nil;
		[[[NSAppleScript alloc] initWithSource:script] executeAndReturnError:&err];
		if (!err) return;
		NSLog(@"[NextZip] mail-attach AppleScript failed (%@): %@", bid, err[NSAppleScriptErrorMessage]);
	}
	// Fallback 1: the system email share service (Apple Mail).
	NSSharingService* mail = [NSSharingService sharingServiceNamed:NSSharingServiceNameComposeEmail];
	if (mail && [mail canPerformWithItems:@[arcURL]]) { [mail performWithItems:@[arcURL]]; return; }
	// Fallback 2: open a blank message in the default app + select the file to drag in.
	[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[arcURL]];
	[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"mailto:?subject=Archive%20attached"]];
	[self _serviceAlert:@"Archive created — attach it manually"
	               info:[NSString stringWithFormat:@"%@\n\nYour mail app couldn't be scripted to attach the file. It's now selected in Finder — drag it into the new message.", path]];
}

- (void)_serviceAlert:(NSString*)msg info:(NSString*)info {
	NSAlert* a = [[NSAlert alloc] init];
	a.messageText = msg; a.informativeText = info ?: @"";
	[a addButtonWithTitle:@"OK"]; [a runModal];
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
