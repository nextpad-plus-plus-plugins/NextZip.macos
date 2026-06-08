/*
 * NineZipDialogs.mm — programmatic modal dialogs (Add / Extract / Info),
 * faithful to the Windows 7-Zip windows (see docs/windows-screens). Control
 * layout, per-format enable/disable, method/dict/word lists and the property
 * mapping mirror CompressDialog.cpp / UpdateGUI.cpp.
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
static NSPopUpButton* nzPopup(void) {
	NSPopUpButton* p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
	[p.widthAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;
	return p;
}
// Fill a popup from @[ @[title, valueObjOrNull], … ]; representedObject = value (nil = Auto).
static void nzFill(NSPopUpButton* p, NSArray<NSArray*>* items) {
	[p removeAllItems];
	for (NSArray* it in items) {
		[p addItemWithTitle:it.firstObject];
		id v = it.count > 1 ? it[1] : [NSNull null];
		p.lastItem.representedObject = [v isKindOfClass:[NSNull class]] ? nil : v;
	}
}
static NSNumber* nzSelNum(NSPopUpButton* p) {
	id o = p.selectedItem.representedObject;
	return [o isKindOfClass:[NSNumber class]] ? o : nil;
}
static NSString* nzSelStr(NSPopUpButton* p) {
	id o = p.selectedItem.representedObject;
	return [o isKindOfClass:[NSString class]] ? o : nil;
}

// ════════════════════════════════════════════════════════════════════════════
// Add to Archive  (full Windows-faithful dialog)
// ════════════════════════════════════════════════════════════════════════════
@interface _NZAddController : NSObject
@property (strong) NSWindow*      win;
@property (strong) NSTextField*   pathField;
@property (strong) NSPopUpButton* fmtPopup;
@property (strong) NSPopUpButton* levelPopup;
@property (strong) NSPopUpButton* methodPopup;
@property (strong) NSPopUpButton* dictPopup;
@property (strong) NSPopUpButton* wordPopup;
@property (strong) NSPopUpButton* solidPopup;
@property (strong) NSPopUpButton* threadsPopup;
@property (strong) NSTextField*   threadsMaxLabel;
@property (strong) NSPopUpButton* memPopup;
@property (strong) NSTextField*   memCompLabel;
@property (strong) NSTextField*   memDecompLabel;
@property (strong) NSTextField*   splitField;
@property (strong) NSTextField*   paramsField;
@property (strong) NSPopUpButton* updatePopup;
@property (strong) NSPopUpButton* pathModePopup;
@property (strong) NSButton*      sfxCheck;
@property (strong) NSButton*      sharedCheck;
@property (strong) NSButton*      deleteCheck;
@property (strong) NSSecureTextField* pwField;
@property (strong) NSSecureTextField* pwField2;
@property (strong) NSTextField*   pwPlain;
@property (strong) NSTextField*   pwPlain2;
@property (strong) NSButton*      showPwCheck;
@property (strong) NSPopUpButton* encMethodPopup;
@property (strong) NSButton*      encNamesCheck;
@end

@implementation _NZAddController

- (void)ok:(id)s {
	if (![[self pwText] isEqualToString:[self pwText2]]) {
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = @"Passwords do not match"; a.informativeText = @"Re-enter the same password in both fields.";
		[a runModal]; return;
	}
	[NSApp stopModalWithCode:NSModalResponseOK];
}
- (void)cancel:(id)s { [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (NSString*)pwText  { return self.showPwCheck.state == NSControlStateValueOn ? self.pwPlain.stringValue  : self.pwField.stringValue; }
- (NSString*)pwText2 { return self.showPwCheck.state == NSControlStateValueOn ? self.pwPlain2.stringValue : self.pwField2.stringValue; }
- (void)showPwToggled:(id)s {
	BOOL show = self.showPwCheck.state == NSControlStateValueOn;
	if (show) { self.pwPlain.stringValue = self.pwField.stringValue; self.pwPlain2.stringValue = self.pwField2.stringValue; }
	else      { self.pwField.stringValue = self.pwPlain.stringValue; self.pwField2.stringValue = self.pwPlain2.stringValue; }
	self.pwField.hidden = show;  self.pwField2.hidden = show;
	self.pwPlain.hidden = !show; self.pwPlain2.hidden = !show;
}
- (void)browse:(id)s {
	NSSavePanel* p = [NSSavePanel savePanel];
	p.nameFieldStringValue = self.pathField.stringValue.lastPathComponent ?: @"archive.7z";
	NSString* dir = [self.pathField.stringValue stringByDeletingLastPathComponent];
	if (dir.length) p.directoryURL = [NSURL fileURLWithPath:dir];
	if ([p runModal] == NSModalResponseOK && p.URL) self.pathField.stringValue = p.URL.path;
}

// ── enable/disable + list rebuild ────────────────────────────────────────────
- (NSString*)fmt { return self.fmtPopup.titleOfSelectedItem ?: @"7z"; }
- (NSString*)method { return self.methodPopup.titleOfSelectedItem ?: @""; }

- (void)formatChanged:(id)s {
	NSString* f = [self fmt];
	NSString* p = self.pathField.stringValue;
	if (p.length) self.pathField.stringValue = [[p stringByDeletingPathExtension] stringByAppendingPathExtension:nzExtForFormat(f)];

	BOOL is7z = [f isEqualToString:@"7z"], isZip = [f isEqualToString:@"zip"], isTar = [f isEqualToString:@"tar"];
	BOOL solidOK = is7z || [f isEqualToString:@"xz"];
	BOOL mtOK    = is7z || isZip || [f isEqualToString:@"bzip2"] || [f isEqualToString:@"xz"];
	BOOL encOK   = is7z || isZip;
	BOOL memOK   = !isTar;

	// methods
	NSArray<NSString*>* methods;
	if (is7z)                              methods = @[@"LZMA2",@"LZMA",@"PPMd",@"BZip2",@"Deflate",@"Deflate64",@"Copy"];
	else if (isZip)                        methods = @[@"Deflate",@"Deflate64",@"BZip2",@"LZMA",@"PPMd"];
	else if ([f isEqualToString:@"gzip"])  methods = @[@"Deflate"];
	else if ([f isEqualToString:@"bzip2"]) methods = @[@"BZip2"];
	else if ([f isEqualToString:@"xz"])    methods = @[@"LZMA2"];
	else                                   methods = @[];   // tar
	[self.methodPopup removeAllItems];
	[self.methodPopup addItemsWithTitles:methods];
	self.methodPopup.enabled = !isTar && methods.count > 0;

	// levels (mask per format)
	NSArray<NSArray*>* allLevels = @[@[@"0 — Store",@0],@[@"1 — Fastest",@1],@[@"3 — Fast",@3],
		@[@"5 — Normal",@5],@[@"7 — Maximum",@7],@[@"9 — Ultra",@9]];
	NSMutableArray<NSArray*>* levs = [NSMutableArray array];
	for (NSArray* lv in allLevels) {
		int n = [lv[1] intValue];
		BOOL ok;
		if (isTar) ok = (n == 0);
		else if ([f isEqualToString:@"gzip"]) ok = (n==1||n==5||n==7||n==9);
		else if ([f isEqualToString:@"bzip2"]) ok = (n==1||n==3||n==5||n==7||n==9);
		else if ([f isEqualToString:@"xz"]) ok = (n!=0);
		else ok = (n==0||n==1||n==3||n==5||n==7||n==9);   // 7z, zip
		if (ok) [levs addObject:lv];
	}
	nzFill(self.levelPopup, levs);
	[self.levelPopup selectItemWithTitle:@"5 — Normal"];
	if (self.levelPopup.indexOfSelectedItem < 0) [self.levelPopup selectItemAtIndex:self.levelPopup.numberOfItems/2];
	self.levelPopup.enabled = !isTar;

	self.solidPopup.enabled   = solidOK;
	self.threadsPopup.enabled = mtOK;
	self.memPopup.enabled     = memOK;

	// encryption method list
	[self.encMethodPopup removeAllItems];
	if (is7z)       [self.encMethodPopup addItemsWithTitles:@[@"AES-256"]];
	else if (isZip) [self.encMethodPopup addItemsWithTitles:@[@"ZipCrypto",@"AES-256"]];
	self.pwField.enabled = self.pwField2.enabled = self.pwPlain.enabled = self.pwPlain2.enabled = encOK;
	self.showPwCheck.enabled = encOK;
	self.encMethodPopup.enabled = encOK;
	self.encNamesCheck.enabled = is7z;
	if (!is7z) self.encNamesCheck.state = NSControlStateValueOff;
	self.sfxCheck.enabled = NO;     // SFX module not shipped on macOS
	self.sfxCheck.toolTip = @"SFX archives are not supported in the macOS build";

	[self methodChanged:nil];
}

- (void)methodChanged:(id)s {
	NSString* m = [self method];
	BOOL store = ([self.levelPopup.selectedItem.representedObject intValue] == 0);
	BOOL isLZMA = [m isEqualToString:@"LZMA"] || [m isEqualToString:@"LZMA2"];
	BOOL isPPMd = [m isEqualToString:@"PPMd"];
	BOOL isBZip = [m isEqualToString:@"BZip2"];
	BOOL isDeflate = [m isEqualToString:@"Deflate"] || [m isEqualToString:@"Deflate64"];

	// dictionary list
	NSMutableArray<NSArray*>* dicts = [NSMutableArray arrayWithObject:@[@"* auto"]];
	if (isLZMA) {
		const unsigned long long K = 1024, M = 1024*1024;
		unsigned long long sizes[] = {64*K,128*K,256*K,512*K,1*M,2*M,3*M,4*M,6*M,8*M,12*M,16*M,24*M,32*M,48*M,64*M,96*M,128*M,192*M,256*M,384*M,512*M,768*M,1024*M,1536*M};
		for (unsigned long long v : sizes)
			[dicts addObject:@[v>=M?[NSString stringWithFormat:@"%llu MB",v/M]:[NSString stringWithFormat:@"%llu KB",v/K],@(v)]];
	} else if (isPPMd) {
		const unsigned long long M = 1024*1024;
		static const unsigned long long mbs[] = {1,2,4,8,16,32,64,128,256,512,1024};
		for (unsigned long long mb : mbs)
			[dicts addObject:@[[NSString stringWithFormat:@"%llu MB",mb],@(mb*M)]];
	} else if (isBZip) {
		const unsigned long long K = 1024;
		static const unsigned long long kbs[] = {100,200,300,400,500,600,700,800,900};
		for (unsigned long long kb : kbs)
			[dicts addObject:@[[NSString stringWithFormat:@"%llu KB",kb],@(kb*K)]];
	}
	nzFill(self.dictPopup, dicts);
	self.dictPopup.enabled = !store && (isLZMA || isPPMd || isBZip);

	// word size / order list
	NSMutableArray<NSArray*>* words = [NSMutableArray arrayWithObject:@[@"* auto"]];
	static const int lzmaW[] = {8,12,16,24,32,48,64,96,128,192,273};
	static const int ppmdO[] = {2,3,4,5,6,8,10,12,16,24,32};
	static const int deflW[] = {8,16,32,64,128,258};
	if (isLZMA)        for (int w : lzmaW) [words addObject:@[@(w).stringValue,@(w)]];
	else if (isPPMd)   for (int o : ppmdO) [words addObject:@[@(o).stringValue,@(o)]];
	else if (isDeflate)for (int w : deflW) [words addObject:@[@(w).stringValue,@(w)]];
	nzFill(self.wordPopup, words);
	self.wordPopup.enabled = !store && (isLZMA || isPPMd || isDeflate);

	[self updateMem];
}
- (void)levelChanged:(id)s { [self methodChanged:nil]; }

- (void)updateMem {
	NSNumber* d = nzSelNum(self.dictPopup);
	if (!d) { self.memCompLabel.stringValue = @"auto"; self.memDecompLabel.stringValue = @"auto"; return; }
	unsigned long long dict = d.unsignedLongLongValue, M = 1024*1024;
	NSString* m = [self method];
	if ([m isEqualToString:@"LZMA"] || [m isEqualToString:@"LZMA2"]) {
		unsigned long long comp = dict / M * 11 + 64, dec = dict / M + 2;
		self.memCompLabel.stringValue   = [NSString stringWithFormat:@"~%llu MB", comp];
		self.memDecompLabel.stringValue = [NSString stringWithFormat:@"~%llu MB", dec];
	} else {
		self.memCompLabel.stringValue   = [NSString stringWithFormat:@"~%llu MB", dict / M + 16];
		self.memDecompLabel.stringValue = [NSString stringWithFormat:@"~%llu MB", dict / M + 2];
	}
}

- (NSGridView*)gridRows:(NSArray<NSArray*>*)rows {
	NSGridView* g = [NSGridView gridViewWithViews:rows];
	g.rowSpacing = 8; g.columnSpacing = 8;
	g.translatesAutoresizingMaskIntoConstraints = NO;
	[g columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
	return g;
}

- (void)buildWithDefaultPath:(NSString*)defPath {
	NSUInteger maxThreads = MAX(1u, (unsigned)[[NSProcessInfo processInfo] activeProcessorCount]);

	self.pathField = [NSTextField textFieldWithString:defPath ?: @""];
	[self.pathField.widthAnchor constraintEqualToConstant:540].active = YES;
	NSButton* dots = [NSButton buttonWithTitle:@"…" target:self action:@selector(browse:)];
	NSStackView* pathRow = nzRow(@[nzLabel(@"Archive:"), self.pathField, dots]);

	self.fmtPopup = nzPopup(); [self.fmtPopup addItemsWithTitles:@[@"7z",@"zip",@"tar",@"gzip",@"bzip2",@"xz"]];
	self.fmtPopup.target = self; self.fmtPopup.action = @selector(formatChanged:);
	self.levelPopup = nzPopup(); self.levelPopup.target = self; self.levelPopup.action = @selector(levelChanged:);
	self.methodPopup = nzPopup(); self.methodPopup.target = self; self.methodPopup.action = @selector(methodChanged:);
	self.dictPopup = nzPopup(); self.dictPopup.target = self; self.dictPopup.action = @selector(memTick:);
	self.wordPopup = nzPopup();
	self.solidPopup = nzPopup();
	nzFill(self.solidPopup, @[@[@"* auto"],@[@"Non-solid",@"off"],@[@"1 MB",@"1048576b"],@[@"4 MB",@"4194304b"],
		@[@"16 MB",@"16777216b"],@[@"64 MB",@"67108864b"],@[@"256 MB",@"268435456b"],@[@"1 GB",@"1073741824b"],
		@[@"4 GB",@"4294967296b"],@[@"8 GB",@"8589934592b"],@[@"Solid",@"on"]]);
	self.threadsPopup = nzPopup();
	NSMutableArray<NSArray*>* th = [NSMutableArray arrayWithObject:@[@"* auto"]];
	for (NSUInteger i = 1; i <= maxThreads; i++) [th addObject:@[@(i).stringValue,@(i)]];
	nzFill(self.threadsPopup, th);
	self.threadsMaxLabel = nzLabel([NSString stringWithFormat:@"/ %lu", (unsigned long)maxThreads]);
	self.memPopup = nzPopup();
	NSMutableArray<NSArray*>* mu = [NSMutableArray arrayWithObject:@[@"* auto"]];
	static const int pcts[] = {10,20,30,40,50,60,70,80,90,100};
	for (int pct : pcts) [mu addObject:@[[NSString stringWithFormat:@"%d%%",pct],[NSString stringWithFormat:@"%d%%",pct]]];
	nzFill(self.memPopup, mu);
	self.memCompLabel = nzLabel(@"auto"); self.memDecompLabel = nzLabel(@"auto");
	self.splitField = [NSTextField textFieldWithString:@""]; self.splitField.placeholderString = @"e.g. 100m (optional)";
	self.paramsField = [NSTextField textFieldWithString:@""]; self.paramsField.placeholderString = @"advanced, e.g. tc=off";

	NSGridView* leftGrid = [self gridRows:@[
		@[nzLabel(@"Archive format:"),     self.fmtPopup],
		@[nzLabel(@"Compression level:"),  self.levelPopup],
		@[nzLabel(@"Compression method:"), self.methodPopup],
		@[nzLabel(@"Dictionary size:"),    self.dictPopup],
		@[nzLabel(@"Word size:"),          self.wordPopup],
		@[nzLabel(@"Solid Block size:"),   self.solidPopup],
		@[nzLabel(@"Number of CPU threads:"), nzRow(@[self.threadsPopup, self.threadsMaxLabel])],
		@[nzLabel(@"Memory for Compressing:"),   nzRow(@[self.memCompLabel, self.memPopup])],
		@[nzLabel(@"Memory for Decompressing:"), self.memDecompLabel],
		@[nzLabel(@"Split to volumes, bytes:"),  self.splitField],
		@[nzLabel(@"Parameters:"),               self.paramsField],
	]];

	// right column
	self.updatePopup = nzPopup();
	[self.updatePopup addItemsWithTitles:@[@"Add and replace files",@"Update and add files",@"Freshen existing files",@"Synchronize files"]];
	self.pathModePopup = nzPopup();
	[self.pathModePopup addItemsWithTitles:@[@"Relative pathnames",@"Full pathnames",@"Absolute pathnames"]];
	NSGridView* rtGrid = [self gridRows:@[
		@[nzLabel(@"Update mode:"), self.updatePopup],
		@[nzLabel(@"Path mode:"),   self.pathModePopup],
	]];

	self.sfxCheck    = [NSButton checkboxWithTitle:@"Create SFX archive" target:nil action:nil];
	self.sharedCheck = [NSButton checkboxWithTitle:@"Compress shared files" target:nil action:nil];
	self.deleteCheck = [NSButton checkboxWithTitle:@"Delete files after compression" target:nil action:nil];
	NSStackView* optsStack = [NSStackView stackViewWithViews:@[self.sfxCheck, self.sharedCheck, self.deleteCheck]];
	optsStack.orientation = NSUserInterfaceLayoutOrientationVertical; optsStack.alignment = NSLayoutAttributeLeading; optsStack.spacing = 6;
	optsStack.edgeInsets = NSEdgeInsetsMake(8,8,8,8);
	NSBox* optsBox = [[NSBox alloc] init]; optsBox.title = @"Options"; optsBox.contentView = optsStack;
	optsBox.translatesAutoresizingMaskIntoConstraints = NO;

	self.pwField  = [[NSSecureTextField alloc] init]; [self.pwField.widthAnchor constraintEqualToConstant:220].active = YES;
	self.pwField2 = [[NSSecureTextField alloc] init]; [self.pwField2.widthAnchor constraintEqualToConstant:220].active = YES;
	self.pwPlain  = [NSTextField textFieldWithString:@""]; self.pwPlain.hidden = YES; [self.pwPlain.widthAnchor constraintEqualToConstant:220].active = YES;
	self.pwPlain2 = [NSTextField textFieldWithString:@""]; self.pwPlain2.hidden = YES; [self.pwPlain2.widthAnchor constraintEqualToConstant:220].active = YES;
	self.showPwCheck = [NSButton checkboxWithTitle:@"Show Password" target:self action:@selector(showPwToggled:)];
	self.encMethodPopup = nzPopup();
	self.encNamesCheck = [NSButton checkboxWithTitle:@"Encrypt file names" target:nil action:nil];
	NSGridView* encGrid = [self gridRows:@[
		@[nzLabel(@"Enter password:"),    nzRow(@[self.pwField,  self.pwPlain])],
		@[nzLabel(@"Reenter password:"),  nzRow(@[self.pwField2, self.pwPlain2])],
		@[[NSGridCell emptyContentView],  self.showPwCheck],
		@[nzLabel(@"Encryption method:"), self.encMethodPopup],
		@[[NSGridCell emptyContentView],  self.encNamesCheck],
	]];
	NSBox* encBox = [[NSBox alloc] init]; encBox.title = @"Encryption"; encBox.contentView = encGrid;
	encBox.contentViewMargins = NSMakeSize(8,8);
	encBox.translatesAutoresizingMaskIntoConstraints = NO;

	NSStackView* rightCol = [NSStackView stackViewWithViews:@[rtGrid, optsBox, encBox]];
	rightCol.orientation = NSUserInterfaceLayoutOrientationVertical;
	rightCol.alignment = NSLayoutAttributeLeading; rightCol.spacing = 12;

	NSStackView* columns = [NSStackView stackViewWithViews:@[leftGrid, rightCol]];
	columns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	columns.alignment = NSLayoutAttributeTop; columns.spacing = 24;

	NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)]; cancel.keyEquivalent = @"\033";
	NSButton* ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(ok:)]; ok.keyEquivalent = @"\r";
	NSView* spacer = [[NSView alloc] init]; [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView* btns = nzRow(@[spacer, cancel, ok]);

	NSStackView* root = [NSStackView stackViewWithViews:@[pathRow, columns, btns]];
	root.orientation = NSUserInterfaceLayoutOrientationVertical;
	root.alignment = NSLayoutAttributeLeading; root.spacing = 14;
	root.edgeInsets = NSEdgeInsetsMake(16,16,16,16);
	root.translatesAutoresizingMaskIntoConstraints = NO;
	[btns.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:16].active = YES;
	[btns.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-16].active = YES;

	NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,620)
		styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
	w.title = @"Add to Archive";
	NSView* c = [[NSView alloc] initWithFrame:w.frame];
	[c addSubview:root];
	[NSLayoutConstraint activateConstraints:@[
		[root.topAnchor constraintEqualToAnchor:c.topAnchor],
		[root.leadingAnchor constraintEqualToAnchor:c.leadingAnchor],
		[root.trailingAnchor constraintEqualToAnchor:c.trailingAnchor],
		[root.bottomAnchor constraintEqualToAnchor:c.bottomAnchor],
	]];
	w.contentView = c;
	[w center];
	self.win = w;
	[self formatChanged:nil];
}
- (void)memTick:(id)s { [self updateMem]; }

- (NZAddOptions*)run {
	NSModalResponse resp = [NSApp runModalForWindow:self.win];
	[self.win orderOut:nil];
	if (resp != NSModalResponseOK) return nil;
	NSString* path = [self.pathField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	if (path.length == 0) return nil;
	NZAddOptions* o = [NZAddOptions new];
	o.archivePath = path;
	o.format = [self fmt];
	o.level = [self.levelPopup.selectedItem.representedObject intValue];
	o.method = self.methodPopup.isEnabled ? [self method] : @"";
	o.dict = nzSelNum(self.dictPopup).unsignedLongLongValue;
	o.wordSize = nzSelNum(self.wordPopup).intValue;
	o.solid = self.solidPopup.isEnabled ? (nzSelStr(self.solidPopup) ?: @"") : @"";
	o.threads = nzSelNum(self.threadsPopup).intValue;
	o.memusePercent = self.memPopup.isEnabled ? (nzSelStr(self.memPopup) ?: @"") : @"";
	o.password = self.pwField.enabled ? [self pwText] : @"";
	NSString* em = self.encMethodPopup.titleOfSelectedItem;
	o.encMethod = (o.password.length && em.length) ? ([em isEqualToString:@"AES-256"] ? @"AES256" : em) : @"";
	o.encryptNames = (self.encNamesCheck.state == NSControlStateValueOn);
	o.pathMode = (int)self.pathModePopup.indexOfSelectedItem;
	o.updateMode = (int)self.updatePopup.indexOfSelectedItem;
	o.createSFX = (self.sfxCheck.state == NSControlStateValueOn);
	o.compressShared = (self.sharedCheck.state == NSControlStateValueOn);
	o.deleteAfter = (self.deleteCheck.state == NSControlStateValueOn);
	o.splitVolume = [self.splitField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	o.extraParams = [self.paramsField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
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
@property (strong) NSPopUpButton* overwritePopup;
@property (strong) NSButton*      eliminateRootCheck;
@property (strong) NSTextField*   pwField;
@end

@implementation _NZExtractController
- (void)ok:(id)s     { [NSApp stopModalWithCode:NSModalResponseOK]; }
- (void)cancel:(id)s { [NSApp stopModalWithCode:NSModalResponseCancel]; }
- (void)browse:(id)s {
	NSOpenPanel* p = [NSOpenPanel openPanel];
	p.canChooseFiles = NO; p.canChooseDirectories = YES; p.canCreateDirectories = YES; p.prompt = @"Choose";
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

	self.subfolderCheck = [NSButton checkboxWithTitle:[NSString stringWithFormat:@"Extract into subfolder “%@”", sub ?: @""] target:nil action:nil];
	self.subfolderCheck.state = NSControlStateValueOn;
	[v addArrangedSubview:self.subfolderCheck];

	self.pathModePopup = nzPopup();
	[self.pathModePopup addItemsWithTitles:@[@"Full pathnames", @"No pathnames"]];
	[v addArrangedSubview:nzRow(@[nzLabel(@"Path mode:"), self.pathModePopup])];

	self.eliminateRootCheck = [NSButton checkboxWithTitle:@"Eliminate duplication of root folder" target:nil action:nil];
	[v addArrangedSubview:self.eliminateRootCheck];

	self.overwritePopup = nzPopup();
	[self.overwritePopup addItemsWithTitles:@[@"Overwrite without prompt", @"Skip existing files", @"Auto rename"]];
	[v addArrangedSubview:nzRow(@[nzLabel(@"Overwrite mode:"), self.overwritePopup])];

	self.pwField = [NSTextField textFieldWithString:@""];
	self.pwField.placeholderString = @"optional";
	[self.pwField.widthAnchor constraintEqualToConstant:240].active = YES;
	[v addArrangedSubview:nzRow(@[nzLabel(@"Password:"), self.pwField])];

	NSButton* cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)]; cancel.keyEquivalent = @"\033";
	NSButton* ok = [NSButton buttonWithTitle:@"Extract" target:self action:@selector(ok:)]; ok.keyEquivalent = @"\r";
	NSView* spacer = [[NSView alloc] init]; [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
	NSStackView* btns = nzRow(@[spacer, cancel, ok]);
	[v addArrangedSubview:btns];
	[btns.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:16].active = YES;
	[btns.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16].active = YES;

	NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,560,310)
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
	w.contentView = c; [w center]; self.win = w;
}
- (NZExtractOptions*)run {
	NSModalResponse resp = [NSApp runModalForWindow:self.win];
	[self.win orderOut:nil];
	if (resp != NSModalResponseOK) return nil;
	NSString* dest = [self.destField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	if (dest.length == 0) return nil;
	NZExtractOptions* o = [NZExtractOptions new];
	o.destDir = dest;
	o.intoSubfolder = (self.subfolderCheck.state == NSControlStateValueOn);
	o.pathMode = (int)self.pathModePopup.indexOfSelectedItem;
	o.overwrite = (int)self.overwritePopup.indexOfSelectedItem;
	o.eliminateRoot = (self.eliminateRootCheck.state == NSControlStateValueOn);
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
	NSString* base = inputs.count == 1 ? [[first lastPathComponent] stringByDeletingPathExtension] : [dir lastPathComponent];
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
		styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];
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
	tv.autoresizingMask = NSViewWidthSizable; tv.textContainer.widthTracksTextView = YES;
	sc.documentView = tv;
	NSButton* ok = [NSButton buttonWithTitle:@"OK" target:NSApp action:@selector(stopModal)];
	ok.keyEquivalent = @"\r"; ok.frame = NSMakeRect(640-100, 6, 90, 30);
	ok.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
	NSView* c = [[NSView alloc] initWithFrame:NSMakeRect(0,0,640,360)];
	[c addSubview:sc]; [c addSubview:ok];
	w.contentView = c; [w center];
	[NSApp runModalForWindow:w];
	[w orderOut:nil];
}
@end
