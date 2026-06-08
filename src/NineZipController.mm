/*
 * NineZipController.mm — archive-manager window (scaffold).
 * NineZip 2026 (GPL). Engine: 7-Zip (LGPL + unRAR restriction).
 */
#import <Cocoa/Cocoa.h>
#include "NineZipController.h"
#include "NppPluginInterfaceMac.h"
#include "SevenZipEngine.h"
#include <memory>

extern "C" NppData* NineZip_HostData();

static NSString* humanSize(uint64_t n) {
	if (n == 0) return @"";
	static const char* u[] = {"B","KB","MB","GB","TB"};
	double v = (double)n; int i = 0;
	while (v >= 1024.0 && i < 4) { v /= 1024.0; i++; }
	return i == 0 ? [NSString stringWithFormat:@"%llu B", (unsigned long long)n]
	              : [NSString stringWithFormat:@"%.1f %s", v, u[i]];
}

@interface NineZipController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@end

@implementation NineZipController {
	const NppData*                    _npp;
	std::unique_ptr<NineZipEngine>    _engine;
	NSWindow*                         _window;
	NSTableView*                      _table;
	NSTextField*                      _pathLabel;
	NSString*                         _archivePath;
}

- (instancetype)initWithNpp:(const NppData*)npp {
	if ((self = [super init])) { _npp = npp; _engine.reset(new NineZipEngine()); }
	return self;
}

// ── window ───────────────────────────────────────────────────────────────────
- (void)ensureWindow {
	if (_window) return;
	NSRect frame = NSMakeRect(0, 0, 900, 520);
	_window = [[NSWindow alloc] initWithContentRect:frame
		styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
		backing:NSBackingStoreBuffered defer:NO];
	_window.title = @"NineZip";
	_window.releasedWhenClosed = NO;
	_window.delegate = self;
	NSView* v = _window.contentView;

	_pathLabel = [NSTextField labelWithString:@""];
	_pathLabel.font = [NSFont systemFontOfSize:11];
	_pathLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[v addSubview:_pathLabel];

	NSScrollView* sc = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	sc.translatesAutoresizingMaskIntoConstraints = NO;
	sc.hasVerticalScroller = YES; sc.hasHorizontalScroller = YES;
	sc.autohidesScrollers = YES; sc.scrollerStyle = NSScrollerStyleOverlay;
	sc.borderType = NSNoBorder;
	_table = [[NSTableView alloc] initWithFrame:NSZeroRect];
	_table.usesAlternatingRowBackgroundColors = YES;
	_table.allowsMultipleSelection = YES;
	struct { NSString* id; NSString* title; CGFloat w; } cols[] = {
		{@"name",@"Name",340}, {@"size",@"Size",90}, {@"pack",@"Packed",90},
		{@"crc",@"CRC",80}, {@"method",@"Method",110}, {@"modified",@"Modified",150},
	};
	for (auto& c : cols) {
		NSTableColumn* tc = [[NSTableColumn alloc] initWithIdentifier:c.id];
		tc.title = c.title; tc.width = c.w;
		tc.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:c.id ascending:YES];
		[_table addTableColumn:tc];
	}
	_table.dataSource = self; _table.delegate = self;
	_table.doubleAction = @selector(onDoubleClick:); _table.target = self;
	sc.documentView = _table;
	[v addSubview:sc];

	[NSLayoutConstraint activateConstraints:@[
		[_pathLabel.topAnchor constraintEqualToAnchor:v.topAnchor constant:8],
		[_pathLabel.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:10],
		[_pathLabel.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-10],
		[sc.topAnchor constraintEqualToAnchor:_pathLabel.bottomAnchor constant:6],
		[sc.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
		[sc.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
		[sc.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
	]];
	[_window center];
}

- (void)show {
	[self ensureWindow];
	[_window makeKeyAndOrderFront:nil];
	[NSApp activateIgnoringOtherApps:YES];
}

// ── open ──────────────────────────────────────────────────────────────────────
- (void)showOpenPanel {
	NSOpenPanel* p = [NSOpenPanel openPanel];
	p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = NO;
	if ([p runModal] == NSModalResponseOK && p.URL)
		[self openArchiveAtPath:p.URL.path];
}

- (void)openCurrentEditorFile {
	char path[4096]; path[0] = 0;
	NppData* d = NineZip_HostData();
	if (d) d->_sendMessage(d->_nppHandle, NPPM_GETFULLCURRENTPATH, sizeof(path), (intptr_t)path);
	if (path[0]) [self openArchiveAtPath:[NSString stringWithUTF8String:path]];
	else         [self showOpenPanel];
}

- (void)openArchiveAtPath:(NSString*)path {
	[self ensureWindow];
	if (!_engine->open(path.UTF8String)) {
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = @"Could not open archive";
		a.informativeText = [NSString stringWithUTF8String:_engine->error().c_str()];
		[a addButtonWithTitle:@"OK"]; [a runModal];
		return;
	}
	_archivePath = path;
	_window.title = [NSString stringWithFormat:@"NineZip — %@", path.lastPathComponent];
	_pathLabel.stringValue = [NSString stringWithFormat:@"%@  (%s, %zu items)",
		path, _engine->format().c_str(), _engine->entries().size()];
	[_table reloadData];
	[self show];
}

// ── table data source ──────────────────────────────────────────────────────────
- (NSInteger)numberOfRowsInTableView:(NSTableView*)t { return (NSInteger)_engine->entries().size(); }

- (id)tableView:(NSTableView*)t objectValueForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
	const std::vector<NZEntry>& e = _engine->entries();
	if (row < 0 || (size_t)row >= e.size()) return @"";
	const NZEntry& it = e[(size_t)row];
	NSString* cid = col.identifier;
	if ([cid isEqual:@"name"])     return [NSString stringWithUTF8String:it.path.c_str()];
	if ([cid isEqual:@"size"])     return humanSize(it.size);
	if ([cid isEqual:@"pack"])     return humanSize(it.packSize);
	if ([cid isEqual:@"crc"])      return it.hasCrc ? [NSString stringWithFormat:@"%08X", it.crc] : @"";
	if ([cid isEqual:@"method"])   return [NSString stringWithUTF8String:it.method.c_str()];
	if ([cid isEqual:@"modified"]) {
		if (it.mtime == 0) return @"";
		NSDate* d = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)it.mtime];
		static NSDateFormatter* df = nil;
		if (!df) { df = [[NSDateFormatter alloc] init]; df.dateFormat = @"yyyy-MM-dd HH:mm"; }
		return [df stringFromDate:d];
	}
	return @"";
}

- (void)onDoubleClick:(id)sender {
	// TODO: descend into folders / nested archives; extract+open file in the editor.
	NSInteger row = _table.clickedRow;
	if (row < 0) return;
	NSLog(@"[NineZip] double-clicked row %ld (descend/extract: TODO)", (long)row);
}

- (void)showAbout {
	NSAlert* a = [[NSAlert alloc] init];
	a.messageText = @"NineZip";
	a.informativeText = @"Archive manager for Nextpad++.\n\nEngine: 7-Zip (LGPL).\n"
	                     "RAR is supported for extraction only (unRAR license — RAR archives cannot be created).\n\nGPL.";
	[a addButtonWithTitle:@"OK"]; [a runModal];
}

- (void)windowWillClose:(NSNotification*)n { /* keep controller alive; window reused */ }
@end
