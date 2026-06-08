/*
 * NineZipDialogs.mm — programmatic modal dialogs (Add / Extract / Info).
 * Modeled on the Windows 7-Zip windows but native AppKit. See NineZipDialogs.h.
 *
 * NineZip 2026 (GPL).
 */
#import "NineZipDialogs.h"

@implementation NZAddOptions @end
@implementation NZExtractOptions @end

// ── small builders ───────────────────────────────────────────────────────────
static NSTextField* nzLabel(NSString* s) {
	NSTextField* l = [NSTextField labelWithString:s];
	l.font = [NSFont systemFontOfSize:12];
	return l;
}
static NSStackView* nzRow(NSArray* views) {
	NSStackView* r = [NSStackView stackViewWithViews:views];
	r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	r.spacing = 8; r.alignment = NSLayoutAttributeCenterY;
	return r;
}
static NSString* nzExtForFormat(NSString* f) {
	if ([f isEqualToString:@"zip"])   return @"zip";
	if ([f isEqualToString:@"tar"])   return @"tar";
	if ([f isEqualToString:@"gzip"])  return @"gz";
	if ([f isEqualToString:@"bzip2"]) return @"bz2";
	if ([f isEqualToString:@"xz"])    return @"xz";
	return @"7z";
}

// ════════════════════════════════════════════════════════════════════════════
// Add to Archive
// ════════════════════════════════════════════════════════════════════════════
@interface _NZAddController : NSObject
@property (strong) NSWindow*      win;
@property (strong) NSTextField*   pathField;
@property (strong) NSPopUpButton* fmtPopup;
@property (strong) NSPopUpButton* levelPopup;
@property (strong) NSTextField*   pwField;
@property (strong) NSButton*      encNamesCheck;
@property (strong) NSButton*      deleteCheck;
@end

@implementation _NZAddController
- (void)ok:(id)s     { [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)s { [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (void)fmtChanged:(id)s {
	NSString* fmt = self.fmtPopup.titleOfSelectedItem ?: @"7z";
	NSString* p = self.pathField.stringValue;
	if (p.length) self.pathField.stringValue =
		[[p stringByDeletingPathExtension] stringByAppendingPathExtension:nzExtForFormat(fmt)];
	BOOL is7z = [fmt isEqualToString:@"7z"];
	self.encNamesCheck.enabled = is7z;
	if (!is7z) self.encNamesCheck.state = NSControlStateValueOff;
}

- (void)buildWithDefaultPath:(NSString*)defPath {
	NSStackView* v = [[NSStackView alloc] init];
	v.orientation = NSUserInterfaceLayoutOrientationVertical;
	v.alignment = NSLayoutAttributeLeading; v.spacing = 10;
	v.translatesAutoresizingMaskIntoConstraints = NO;
	v.edgeInsets = NSEdgeInsetsMake(16,16,16,16);

	self.pathField = [NSTextField textFieldWithString:defPath ?: @""];
	[self.pathField.widthAnchor constraintEqualToConstant:430].active = YES;
	[v addArrangedSubview:nzRow(@[nzLabel(@"Archive:"), self.pathField])];

	self.fmtPopup = [[NSPopUpButton alloc] init];
	[self.fmtPopup addItemsWithTitles:@[@"7z",@"zip",@"tar",@"gzip",@"bzip2",@"xz"]];
	self.fmtPopup.target = self; self.fmtPopup.action = @selector(fmtChanged:);
	self.levelPopup = [[NSPopUpButton alloc] init];
	[self.levelPopup addItemsWithTitles:@[@"Store",@"Fastest",@"Fast",@"Normal",@"Maximum",@"Ultra"]];
	[self.levelPopup selectItemAtIndex:3];
	[v addArrangedSubview:nzRow(@[nzLabel(@"Format:"), self.fmtPopup, nzLabel(@"   Level:"), self.levelPopup])];

	self.pwField = [NSTextField textFieldWithString:@""];
	self.pwField.placeholderString = @"optional";
	[self.pwField.widthAnchor constraintEqualToConstant:240].active = YES;
	[v addArrangedSubview:nzRow(@[nzLabel(@"Password:"), self.pwField])];

	self.encNamesCheck = [NSButton checkboxWithTitle:@"Encrypt file names (7z only)" target:nil action:nil];
	self.deleteCheck   = [NSButton checkboxWithTitle:@"Delete files after compression" target:nil action:nil];
	[v addArrangedSubview:self.encNamesCheck];
	[v addArrangedSubview:self.deleteCheck];

	NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
	cancel.keyEquivalent = @"\033";
	NSButton* ok = [NSButton buttonWithTitle:@"Add" target:self action:@selector(ok:)];
	ok.keyEquivalent = @"\r";
	NSView* spacer = [[NSView alloc] init];
	[spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView* btns = nzRow(@[spacer, cancel, ok]);
	[v addArrangedSubview:btns];
	[btns.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor  constant:16].active = YES;
	[btns.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16].active = YES;

	NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,500,250)
		styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	w.title = @"Add to Archive";
	NSView* c = [[NSView alloc] initWithFrame:w.frame];
	[c addSubview:v];
	[NSLayoutConstraint activateConstraints:@[
		[v.topAnchor constraintEqualToAnchor:c.topAnchor],
		[v.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
		[v.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
		[v.bottomAnchor constraintEqualToAnchor:c.bottomAnchor],
	]];
	w.contentView = c;
	[w center];
	self.win = w;
	[self fmtChanged:nil];
}

- (NZAddOptions*)run {
	NSModalResponse resp = [NSApp runModalForWindow:self.win];
	[self.win orderOut:nil];
	if (resp != NSModalResponseOK) return nil;
	NSString* path = [self.pathField.stringValue stringByTrimmingCharactersInSet:
	                  [NSCharacterSet whitespaceCharacterSet]];
	if (path.length == 0) return nil;
	NZAddOptions* o = [NZAddOptions new];
	o.archivePath = path;
	o.format = self.fmtPopup.titleOfSelectedItem ?: @"7z";
	static const int levels[] = {0,1,3,5,7,9};
	NSInteger li = self.levelPopup.indexOfSelectedItem; if (li < 0 || li > 5) li = 3;
	o.level = levels[li];
	o.password = self.pwField.stringValue ?: @"";
	o.encryptNames = (self.encNamesCheck.state == NSControlStateValueOn);
	o.deleteAfter = (self.deleteCheck.state == NSControlStateValueOn);
	return o;
}
@end

// ════════════════════════════════════════════════════════════════════════════
// Extract
// ════════════════════════════════════════════════════════════════════════════
@interface _NZExtractController : NSObject
@property (strong) NSWindow*      win;
@property (strong) NSTextField*   destField;
@property (strong) NSButton*      subfolderCheck;
@property (strong) NSPopUpButton* pathModePopup;
@property (strong) NSTextField*   pwField;
@end

@implementation _NZExtractController
- (void)ok:(id)s     { [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)s { [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (void)browse:(id)s {
	NSOpenPanel* p = [NSOpenPanel openPanel];
	p.canChooseFiles = NO; p.canChooseDirectories = YES; p.canCreateDirectories = YES;
	p.prompt = @"Choose";
	NSString* cur = self.destField.stringValue;
	if (cur.length) p.directoryURL = [NSURL fileURLWithPath:cur];
	if ([p runModal] == NSModalResponseOK && p.URL) self.destField.stringValue = p.URL.path;
}

- (void)buildWithDefaultDir:(NSString*)dir subfolder:(NSString*)sub {
	NSStackView* v = [[NSStackView alloc] init];
	v.orientation = NSUserInterfaceLayoutOrientationVertical;
	v.alignment = NSLayoutAttributeLeading; v.spacing = 10;
	v.translatesAutoresizingMaskIntoConstraints = NO;
	v.edgeInsets = NSEdgeInsetsMake(16,16,16,16);

	self.destField = [NSTextField textFieldWithString:dir ?: @""];
	[self.destField.widthAnchor constraintEqualToConstant:380].active = YES;
	NSButton* browse = [NSButton buttonWithTitle:@"Browse…" target:self action:@selector(browse:)];
	[v addArrangedSubview:nzRow(@[nzLabel(@"Extract to:"), self.destField, browse])];

	self.subfolderCheck = [NSButton checkboxWithTitle:
		[NSString stringWithFormat:@"Extract into subfolder “%@”", sub ?: @""]
		target:nil action:nil];
	self.subfolderCheck.state = NSControlStateValueOn;
	[v addArrangedSubview:self.subfolderCheck];

	self.pathModePopup = [[NSPopUpButton alloc] init];
	[self.pathModePopup addItemsWithTitles:@[@"Full pathnames", @"No pathnames"]];
	[v addArrangedSubview:nzRow(@[nzLabel(@"Path mode:"), self.pathModePopup])];

	self.pwField = [NSTextField textFieldWithString:@""];
	self.pwField.placeholderString = @"optional";
	[self.pwField.widthAnchor constraintEqualToConstant:240].active = YES;
	[v addArrangedSubview:nzRow(@[nzLabel(@"Password:"), self.pwField])];

	NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
	cancel.keyEquivalent = @"\033";
	NSButton* ok = [NSButton buttonWithTitle:@"Extract" target:self action:@selector(ok:)];
	ok.keyEquivalent = @"\r";
	NSView* spacer = [[NSView alloc] init];
	[spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView* btns = nzRow(@[spacer, cancel, ok]);
	[v addArrangedSubview:btns];
	[btns.leadingAnchor  constraintEqualToAnchor:v.leadingAnchor  constant:16].active = YES;
	[btns.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16].active = YES;

	NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,520,220)
		styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	w.title = @"Extract";
	NSView* c = [[NSView alloc] initWithFrame:w.frame];
	[c addSubview:v];
	[NSLayoutConstraint activateConstraints:@[
		[v.topAnchor constraintEqualToAnchor:c.topAnchor],
		[v.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
		[v.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
		[v.bottomAnchor constraintEqualToAnchor:c.bottomAnchor],
	]];
	w.contentView = c;
	[w center];
	self.win = w;
}

- (NZExtractOptions*)run {
	NSModalResponse resp = [NSApp runModalForWindow:self.win];
	[self.win orderOut:nil];
	if (resp != NSModalResponseOK) return nil;
	NSString* dest = [self.destField.stringValue stringByTrimmingCharactersInSet:
	                  [NSCharacterSet whitespaceCharacterSet]];
	if (dest.length == 0) return nil;
	NZExtractOptions* o = [NZExtractOptions new];
	o.destDir = dest;
	o.intoSubfolder = (self.subfolderCheck.state == NSControlStateValueOn);
	o.pathMode = (int)self.pathModePopup.indexOfSelectedItem;   // 0 full, 1 none
	o.password = self.pwField.stringValue ?: @"";
	return o;
}
@end

// ════════════════════════════════════════════════════════════════════════════
@implementation NineZipDialogs

+ (NZAddOptions*)runAddForInputs:(NSArray<NSString*>*)inputs {
	if (inputs.count == 0) return nil;
	NSString* first = inputs.firstObject;
	NSString* dir = [first stringByDeletingLastPathComponent];
	NSString* base;
	if (inputs.count == 1) base = [[first lastPathComponent] stringByDeletingPathExtension];
	else                   base = [dir lastPathComponent];
	if (base.length == 0) base = @"Archive";
	NSString* def = [dir stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"7z"]];

	_NZAddController* c = [_NZAddController new];
	[c buildWithDefaultPath:def];
	return [c run];
}

+ (NZExtractOptions*)runExtractForArchive:(NSString*)archivePath {
	if (archivePath.length == 0) return nil;
	NSString* dir = [archivePath stringByDeletingLastPathComponent];
	NSString* sub = [[archivePath lastPathComponent] stringByDeletingPathExtension];
	_NZExtractController* c = [_NZExtractController new];
	[c buildWithDefaultDir:dir subfolder:sub];
	return [c run];
}

+ (void)showInfoTitle:(NSString*)title text:(NSString*)text {
	NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,640,360)
		styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskResizable)
		backing:NSBackingStoreBuffered defer:NO];
	w.title = title ?: @"Information";

	NSScrollView* sc = [[NSScrollView alloc] initWithFrame:NSMakeRect(0,40,640,320)];
	sc.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	sc.hasVerticalScroller = YES; sc.borderType = NSNoBorder;
	NSTextView* tv = [[NSTextView alloc] initWithFrame:sc.bounds];
	tv.editable = NO; tv.selectable = YES;
	tv.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
	tv.textContainerInset = NSMakeSize(10,10);
	tv.string = text ?: @"";
	tv.minSize = NSMakeSize(0,0); tv.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
	tv.verticallyResizable = YES; tv.horizontallyResizable = NO;
	tv.autoresizingMask = NSViewWidthSizable;
	tv.textContainer.widthTracksTextView = YES;
	sc.documentView = tv;

	NSButton* ok = [NSButton buttonWithTitle:@"OK" target:NSApp action:@selector(stopModal)];
	ok.keyEquivalent = @"\r";
	ok.frame = NSMakeRect(640-100, 6, 90, 30);
	ok.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;

	NSView* c = [[NSView alloc] initWithFrame:NSMakeRect(0,0,640,360)];
	[c addSubview:sc]; [c addSubview:ok];
	w.contentView = c;
	[w center];
	[NSApp runModalForWindow:w];
	[w orderOut:nil];
}
@end
