/*
 * NextZipController.mm — the NextZip archive File-Manager window.
 *
 * Browse an archive like a filesystem (folder tree built from entry paths),
 * breadcrumb + Up navigation, toolbar (Open/Up/Extract/Test/Info), and — the
 * point — open a file from the archive in the Nextpad++ editor by extracting it
 * on the fly to a temp folder, plus Extract/Test to disk.
 *
 * NextZip 2026 (GPL). Engine: 7-Zip (LGPL + unRAR restriction; RAR extract-only).
 */
#import <Cocoa/Cocoa.h>
#include "NextZipController.h"
#include "NextZipDialogs.h"
#include "SevenZipEngine.h"
#include <memory>
#include <vector>
#include <string>
#include <algorithm>
#include <functional>
#include <cctype>
#include <map>
#include <utility>

// This file is host-agnostic: it never references NppData / NPPM_* directly.
// Everything host-specific goes through self.host (id<NextZipHost>), so the same
// controller links into both the Nextpad++ plugin and the standalone app.

// ── virtual folder tree built from the flat entry list ───────────────────────
namespace {
struct FMNode {
	std::string name;
	bool        isDir = false;
	int         entryIndex = -1;          // index into engine.entries(), or -1 (synthetic dir)
	FMNode*     parent = nullptr;
	std::vector<FMNode*> children;
};

void freeTree(FMNode* n) { if (!n) return; for (auto c : n->children) freeTree(c); delete n; }

// A chain of nested-archive layers, outer → inner. .first = the archive file on
// disk (real for [0], a temp for unwrapped inner layers); .second = the single
// entry name inside that layer which yielded the next one (used to re-wrap on
// save). Length 1 for an ordinary archive; longer for .tar.gz etc.
using ArcChain = std::vector<std::pair<std::string,std::string>>;

// Which formats are single-stream compressors that wrap exactly one payload —
// the ones we transparently unwrap (e.g. site.tar.gz → show the inner tar).
bool isSingleStream(const std::string& fmt) {
	return fmt == "gzip" || fmt == "bzip2" || fmt == "xz" || fmt == "z";
}

// A file extracted to temp and opened in the editor → how to write it back.
struct OpenedTemp {
	std::string entryPath;   // path inside the innermost archive
	ArcChain    chain;       // layer chain captured at open time (for re-wrap)
};

std::vector<std::string> splitPath(const std::string& p) {
	std::vector<std::string> out; std::string cur;
	for (char c : p) {
		if (c == '/' || c == '\\') { if (!cur.empty()) { out.push_back(cur); cur.clear(); } }
		else cur += c;
	}
	if (!cur.empty()) out.push_back(cur);
	return out;
}

FMNode* findOrAddDir(FMNode* p, const std::string& name) {
	for (auto c : p->children) if (c->isDir && c->name == name) return c;
	FMNode* n = new FMNode; n->isDir = true; n->name = name; n->parent = p;
	p->children.push_back(n); return n;
}

// Path of a node as a list of folder names from the root (root excluded). Used
// to re-resolve the current directory after the tree is freed + rebuilt.
std::vector<std::string> nodePath(FMNode* n) {
	std::vector<std::string> p;
	for (FMNode* c = n; c && c->parent; c = c->parent) p.push_back(c->name);
	std::reverse(p.begin(), p.end());
	return p;
}

// Find a directory node by its name-path in a (re)built tree; nullptr if any
// component is missing (e.g. the folder was removed).
FMNode* findDirByPath(FMNode* root, const std::vector<std::string>& path) {
	FMNode* cur = root;
	for (const std::string& name : path) {
		FMNode* next = nullptr;
		for (auto c : cur->children) if (c->isDir && c->name == name) { next = c; break; }
		if (!next) return nullptr;
		cur = next;
	}
	return cur;
}

FMNode* buildTree(const std::vector<NZEntry>& entries) {
	FMNode* root = new FMNode; root->isDir = true;
	for (int i = 0; i < (int)entries.size(); i++) {
		std::vector<std::string> comps = splitPath(entries[i].path);
		if (comps.empty()) continue;
		FMNode* cur = root;
		for (size_t k = 0; k + 1 < comps.size(); k++) cur = findOrAddDir(cur, comps[k]);
		const std::string& leaf = comps.back();
		if (entries[i].isDir) findOrAddDir(cur, leaf)->entryIndex = i;
		else { FMNode* f = new FMNode; f->name = leaf; f->entryIndex = i; f->parent = cur; cur->children.push_back(f); }
	}
	// sort each folder: dirs first, then case-insensitive name
	std::function<void(FMNode*)> sortNode = [&](FMNode* n) {
		std::sort(n->children.begin(), n->children.end(), [](FMNode* a, FMNode* b) {
			if (a->isDir != b->isDir) return a->isDir > b->isDir;
			std::string x = a->name, y = b->name;
			std::transform(x.begin(), x.end(), x.begin(), ::tolower);
			std::transform(y.begin(), y.end(), y.begin(), ::tolower);
			return x < y;
		});
		for (auto c : n->children) sortNode(c);
	};
	sortNode(root);
	return root;
}

void gatherEntryIndices(FMNode* n, std::vector<uint32_t>& out) {
	if (n->entryIndex >= 0) out.push_back((uint32_t)n->entryIndex);
	for (auto c : n->children) gatherEntryIndices(c, out);
}

NSString* humanSize(uint64_t n) {
	if (n == 0) return @"";
	static const char* u[] = {"B","KB","MB","GB","TB"};
	double v = (double)n; int i = 0;
	while (v >= 1024.0 && i < 4) { v /= 1024.0; i++; }
	return i == 0 ? [NSString stringWithFormat:@"%llu B", (unsigned long long)n]
	              : [NSString stringWithFormat:@"%.1f %s", v, u[i]];
}

BOOL pathIsDir(NSString* p) {
	BOOL d = NO; return [[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&d] && d;
}
// Quick extension heuristic for building the right-click menu (the actual open is
// always content-detected). Folders are never archives.
BOOL looksLikeArchive(NSString* path) {
	if (pathIsDir(path)) return NO;
	static NSSet* exts;
	if (!exts) exts = [NSSet setWithArray:@[@"7z",@"zip",@"rar",@"tar",@"gz",@"tgz",@"bz2",@"tbz",
		@"tbz2",@"xz",@"txz",@"z",@"taz",@"cab",@"iso",@"dmg",@"wim",@"swm",@"arj",@"lzh",@"lha",
		@"rpm",@"deb",@"xar",@"pkg",@"xip",@"cpio",@"jar",@"war",@"apk",@"chm",@"udf",@"vhd",
		@"vhdx",@"vdi",@"vmdk",@"qcow",@"qcow2",@"cramfs",@"squashfs"]];
	return [exts containsObject:path.pathExtension.lowercaseString];
}
} // namespace

// ─────────────────────────────────────────────────────────────────────────────
@interface NextZipController () <NSTableViewDataSource, NSTableViewDelegate,
                                NSOutlineViewDataSource, NSOutlineViewDelegate,
                                NSMenuDelegate, NSWindowDelegate, NSSearchFieldDelegate>
@end

@implementation NextZipController {
	std::unique_ptr<NextZipEngine> _engine;
	FMNode*                        _root;
	FMNode*                        _cwd;
	std::vector<FMNode*>           _ancestors;   // root..cwd, parallel to breadcrumb items
	NSString*                      _archivePath;   // innermost archive the engine is open on (may be a temp)
	NSString*                      _archivePassword; // password that unlocked the on-screen archive (session cache)
	NSString*                      _displayPath;   // outermost real file the user clicked (for the breadcrumb)
	ArcChain                       _layers;        // outer→inner nested-archive chain for the current view
	NSView*                        _panelView;     // the archive-manager content view (shared by both shells)
	NSTableView*                   _table;
	std::vector<FMNode*>           _visibleRows;   // _cwd->children after the name filter (what the table shows)
	NSString*                      _arcFilter;     // current archive-pane name filter ("" = show all)
	NSSearchField*                 _searchField;   // archive-pane name filter (app only); nil in the plugin
	NSPathControl*                 _breadcrumb;
	NSOutlineView*                 _fsOutline;       // top pane: filesystem browser
	NSArray<NSURL*>*               _fsRoots;
	NSMutableDictionary*           _fsChildrenCache; // NSURL → NSArray<NSURL*>
	NSMenu*                        _fsMenu;          // top-pane right-click menu
	NSMenu*                        _arcMenu;         // bottom-pane right-click menu
	// temp files opened in the editor → how to write them back (incl. nested chain)
	std::map<std::string, OpenedTemp> _openedTemps;
}

- (instancetype)init {
	if ((self = [super init])) { _engine.reset(new NextZipEngine()); _root = _cwd = nullptr; }
	return self;
}
- (void)dealloc { freeTree(_root); }

- (void)setEnginePath:(NSString*)sevenZipSoPath {
	if (sevenZipSoPath.length && _engine) _engine->setEnginePath(sevenZipSoPath.UTF8String);
}

// ── window + toolbar ─────────────────────────────────────────────────────────
// One toolbar item. In the standalone app on macOS 26+, each icon is its OWN
// Tahoe Liquid Glass capsule (NSGlassEffectView); the plugin and older macOS get
// a plain textured button, so this is purely additive to the app.
- (NSView*)toolButton:(NSString*)tip symbol:(NSString*)sym action:(SEL)a {
	NSButton* b = [NSButton buttonWithTitle:@"" target:self action:a];
	NSImage* img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:tip];
	if (img) { b.image = img; b.imagePosition = NSImageOnly; }
	else     { b.title = tip; b.font = [NSFont systemFontOfSize:10]; }
	b.toolTip = tip;
	b.translatesAutoresizingMaskIntoConstraints = NO;

	if (_usesGlassToolbars) {
		if (@available(macOS 26.0, *)) {
			// Borderless symbol centered in its own glass pill (the capsule is the chrome).
			b.bordered = NO; b.bezelStyle = NSBezelStyleRegularSquare;
			b.contentTintColor = [NSColor labelColor];
			[b.widthAnchor  constraintEqualToConstant:34].active = YES;
			[b.heightAnchor constraintEqualToConstant:28].active = YES;
			NSGlassEffectView* g = [[NSGlassEffectView alloc] init];
			g.translatesAutoresizingMaskIntoConstraints = NO;
			g.cornerRadius = 14;                 // half the height → capsule
			g.contentView = b;
			[g.widthAnchor  constraintEqualToConstant:34].active = YES;
			[g.heightAnchor constraintEqualToConstant:28].active = YES;
			// Hover feedback: subtle grey tint on the capsule. Tracking-area owner
			// is the controller; the capsule rides along in userInfo (nonretained
			// to avoid a view→area→userInfo→view retain cycle).
			NSTrackingArea* ta = [[NSTrackingArea alloc] initWithRect:NSZeroRect
				options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect)
				owner:self userInfo:@{ @"nzGlass": [NSValue valueWithNonretainedObject:g] }];
			[g addTrackingArea:ta];
			return g;
		}
	}
	b.bezelStyle = NSBezelStyleTexturedRounded;
	[b.widthAnchor constraintEqualToConstant:38].active = YES;
	return b;
}

// Hover feedback for the Liquid Glass toolbar capsules (app only; the controller
// is the tracking-area owner, each event identifies its capsule via userInfo).
- (void)mouseEntered:(NSEvent*)event {
	if (@available(macOS 26.0, *)) {
		id g = [event.trackingArea.userInfo[@"nzGlass"] nonretainedObjectValue];
		if ([g isKindOfClass:[NSGlassEffectView class]])
			((NSGlassEffectView*)g).tintColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.22];
	}
}
- (void)mouseExited:(NSEvent*)event {
	if (@available(macOS 26.0, *)) {
		id g = [event.trackingArea.userInfo[@"nzGlass"] nonretainedObjectValue];
		if ([g isKindOfClass:[NSGlassEffectView class]])
			((NSGlassEffectView*)g).tintColor = nil;
	}
}

- (void)ensurePanel {
	if (_panelView) return;
	NSView* v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,760,560)];
	v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;   // host stretches us
	_panelView = v;

	// ── TOP pane: toolbar (Add/Extract/Test/Delete/Info) + filesystem browser ──
	NSView* top = [[NSView alloc] initWithFrame:NSZeroRect];
	top.translatesAutoresizingMaskIntoConstraints = NO;
	NSStackView* fstb = [NSStackView stackViewWithViews:@[
		[self toolButton:@"Add to archive…" symbol:@"plus" action:@selector(fsAdd:)],
		[self toolButton:@"Extract…" symbol:@"arrow.down.doc" action:@selector(fsExtract:)],
		[self toolButton:@"Test archive" symbol:@"checkmark.shield" action:@selector(fsTest:)],
		[self toolButton:@"Delete (to Trash)" symbol:@"trash" action:@selector(fsDelete:)],
		[self toolButton:@"Info / Checksum" symbol:@"info.circle" action:@selector(fsInfo:)],
	]];
	fstb.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	fstb.spacing = 6; fstb.translatesAutoresizingMaskIntoConstraints = NO;
	[top addSubview:fstb];

	NSScrollView* fsScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	fsScroll.translatesAutoresizingMaskIntoConstraints = NO;
	fsScroll.hasVerticalScroller = YES; fsScroll.autohidesScrollers = YES;
	fsScroll.scrollerStyle = NSScrollerStyleOverlay; fsScroll.borderType = NSNoBorder;
	_fsOutline = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
	NSTableColumn* fc = [[NSTableColumn alloc] initWithIdentifier:@"fs"];
	fc.title = @"Disk"; [_fsOutline addTableColumn:fc]; _fsOutline.outlineTableColumn = fc;
	_fsOutline.headerView = nil; _fsOutline.dataSource = self; _fsOutline.delegate = self;
	_fsOutline.target = self; _fsOutline.doubleAction = @selector(onFsDoubleClick:);
	_fsOutline.allowsMultipleSelection = YES;
	_fsMenu = [[NSMenu alloc] initWithTitle:@"fs"]; _fsMenu.delegate = self; _fsOutline.menu = _fsMenu;
	fsScroll.documentView = _fsOutline;
	[top addSubview:fsScroll];
	_fsChildrenCache = [NSMutableDictionary dictionary];
	_fsRoots = @[ [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES],
	              [NSURL fileURLWithPath:@"/" isDirectory:YES] ];
	[NSLayoutConstraint activateConstraints:@[
		[fstb.topAnchor constraintEqualToAnchor:top.topAnchor constant:6],
		[fstb.leadingAnchor constraintEqualToAnchor:top.leadingAnchor constant:8],
		[fsScroll.topAnchor constraintEqualToAnchor:fstb.bottomAnchor constant:4],
		[fsScroll.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
		[fsScroll.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
		[fsScroll.bottomAnchor constraintEqualToAnchor:top.bottomAnchor],
	]];

	// ── BOTTOM pane: archive contents (breadcrumb ABOVE the toolbar, then table) ──
	NSView* arc = [[NSView alloc] initWithFrame:NSZeroRect];
	arc.translatesAutoresizingMaskIntoConstraints = NO;

	_breadcrumb = [[NSPathControl alloc] initWithFrame:NSZeroRect];
	_breadcrumb.translatesAutoresizingMaskIntoConstraints = NO;
	_breadcrumb.pathStyle = NSPathStyleStandard; _breadcrumb.editable = NO;
	_breadcrumb.controlSize = NSControlSizeSmall;                 // compact breadcrumb
	_breadcrumb.font = [NSFont systemFontOfSize:11];
	_breadcrumb.target = self; _breadcrumb.action = @selector(actBreadcrumb:);
	[arc addSubview:_breadcrumb];

	NSStackView* tb = [NSStackView stackViewWithViews:@[
		[self toolButton:@"Open archive…" symbol:@"folder" action:@selector(actOpen:)],
		[self toolButton:@"Up" symbol:@"arrow.up" action:@selector(actUp:)],
		[self toolButton:@"Extract…" symbol:@"square.and.arrow.up" action:@selector(actExtract:)],
		[self toolButton:@"Test" symbol:@"checkmark.shield" action:@selector(actTest:)],
		[self toolButton:@"Info" symbol:@"info.circle" action:@selector(actInfo:)],
	]];
	tb.orientation = NSUserInterfaceLayoutOrientationHorizontal;
	tb.spacing = 6; tb.translatesAutoresizingMaskIntoConstraints = NO;
	[arc addSubview:tb];

	// App only: a live name filter to the right of the archive toolbar.
	if (_sideBySidePanes) {
		_searchField = [[NSSearchField alloc] init];
		_searchField.translatesAutoresizingMaskIntoConstraints = NO;
		_searchField.placeholderString = @"Filter";
		_searchField.sendsWholeSearchString = NO;
		_searchField.delegate = self;             // live filter via -controlTextDidChange:
		[arc addSubview:_searchField];
	}

	NSScrollView* sc = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	sc.translatesAutoresizingMaskIntoConstraints = NO;
	sc.hasVerticalScroller = YES; sc.hasHorizontalScroller = YES;
	sc.autohidesScrollers = YES; sc.scrollerStyle = NSScrollerStyleOverlay; sc.borderType = NSNoBorder;
	_table = [[NSTableView alloc] initWithFrame:NSZeroRect];
	_table.usesAlternatingRowBackgroundColors = YES; _table.allowsMultipleSelection = YES;
	struct { NSString* cid; NSString* title; CGFloat w; } cols[] = {
		{@"name",@"Name",340}, {@"size",@"Size",90}, {@"pack",@"Packed",90},
		{@"crc",@"CRC",80}, {@"method",@"Method",110}, {@"modified",@"Modified",140},
	};
	for (auto& c : cols) {
		NSTableColumn* tc = [[NSTableColumn alloc] initWithIdentifier:c.cid]; tc.title = c.title; tc.width = c.w;
		[_table addTableColumn:tc];
	}
	_table.dataSource = self; _table.delegate = self;
	_table.doubleAction = @selector(onDoubleClick:); _table.target = self;
	_arcMenu = [[NSMenu alloc] initWithTitle:@"arc"]; _arcMenu.delegate = self; _table.menu = _arcMenu;
	sc.documentView = _table;
	[arc addSubview:sc];
	// Orientation-independent constraints for the archive pane.
	NSMutableArray<NSLayoutConstraint*>* arcCons = [@[
		[_breadcrumb.leadingAnchor constraintEqualToAnchor:arc.leadingAnchor constant:8],
		[_breadcrumb.trailingAnchor constraintEqualToAnchor:arc.trailingAnchor constant:-8],
		[_breadcrumb.heightAnchor constraintEqualToConstant:16],
		[tb.leadingAnchor constraintEqualToAnchor:arc.leadingAnchor constant:8],
		[sc.leadingAnchor constraintEqualToAnchor:arc.leadingAnchor],
		[sc.trailingAnchor constraintEqualToAnchor:arc.trailingAnchor],
		[sc.bottomAnchor constraintEqualToAnchor:arc.bottomAnchor],
	] mutableCopy];
	if (_sideBySidePanes) {
		// App: toolbar on top, breadcrumb beneath it, then the table.
		[arcCons addObjectsFromArray:@[
			[tb.topAnchor constraintEqualToAnchor:arc.topAnchor constant:6],
			[_breadcrumb.topAnchor constraintEqualToAnchor:tb.bottomAnchor constant:6],
			[sc.topAnchor constraintEqualToAnchor:_breadcrumb.bottomAnchor constant:4],
			// Filter field: right-aligned, vertically centered on the toolbar row.
			[_searchField.centerYAnchor constraintEqualToAnchor:tb.centerYAnchor],
			[_searchField.trailingAnchor constraintEqualToAnchor:arc.trailingAnchor constant:-8],
			[_searchField.leadingAnchor constraintGreaterThanOrEqualToAnchor:tb.trailingAnchor constant:12],
		]];
		NSLayoutConstraint* sw = [_searchField.widthAnchor constraintEqualToConstant:200];
		sw.priority = NSLayoutPriorityDefaultHigh;   // prefer 200pt; shrink in a narrow pane
		[arcCons addObject:sw];
	} else {
		// Plugin: breadcrumb on top, then toolbar, then the table.
		[arcCons addObjectsFromArray:@[
			[_breadcrumb.topAnchor constraintEqualToAnchor:arc.topAnchor constant:5],
			[tb.topAnchor constraintEqualToAnchor:_breadcrumb.bottomAnchor constant:4],
			[sc.topAnchor constraintEqualToAnchor:tb.bottomAnchor constant:4],
		]];
	}
	[NSLayoutConstraint activateConstraints:arcCons];

	// Split the two panes. Default (plugin): stacked — FS browser on top, archive
	// below. Standalone app (sideBySidePanes): Finder-like — FS browser on the
	// LEFT, archive viewer on the RIGHT. Each pane keeps its own toolbar at its top.
	NSSplitView* split = [[NSSplitView alloc] initWithFrame:v.bounds];
	split.translatesAutoresizingMaskIntoConstraints = NO;
	split.vertical = _sideBySidePanes;   // YES → vertical divider → panes side by side
	split.dividerStyle = NSSplitViewDividerStyleThin;
	[split addArrangedSubview:top];      // first  = top (stacked) / left  (side-by-side)
	[split addArrangedSubview:arc];      // second = bottom (stacked) / right (side-by-side)
	[v addSubview:split];
	[NSLayoutConstraint activateConstraints:@[
		[split.topAnchor constraintEqualToAnchor:v.topAnchor],
		[split.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
		[split.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
		[split.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
	]];
	[v layoutSubtreeIfNeeded];
	if (_sideBySidePanes) {
		[split setPosition:300 ofDividerAtIndex:0];   // ~300px FS pane on the left
		// Keep the FS pane's width when the window resizes; the archive viewer grows.
		[split setHoldingPriority:NSLayoutPriorityDefaultLow + 1 forSubviewAtIndex:0];
	} else {
		[split setPosition:200 ofDividerAtIndex:0];   // ~200px FS pane on top
	}
	[_fsOutline reloadData];
	// NOTE: panel hosting (dock-register for the plugin, window contentView for
	// the app) is the shell's job — this method only builds the view.
}

// The shared archive-manager view. Built lazily; the shell hosts it.
- (NSView*)panelView { [self ensurePanel]; return _panelView; }

// Outermost real archive on screen (the app uses this for the window title).
- (NSString*)currentArchivePath { return _displayPath; }

// ── open ──────────────────────────────────────────────────────────────────────
- (void)showOpenPanel {
	NSOpenPanel* p = [NSOpenPanel openPanel];
	p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = NO;
	if ([p runModal] == NSModalResponseOK && p.URL) [self openArchiveAtPath:p.URL.path];
}
- (void)openCurrentEditorFile {
	NSString* p = [self.host nextZipCurrentFilePath];
	if (p.length) [self openArchiveAtPath:p];
	else          [self showOpenPanel];
}

- (void)openArchiveAtPath:(NSString*)path { [self openArchiveAtPath:path quiet:NO]; }
- (void)openArchiveAtPath:(NSString*)path quiet:(BOOL)quiet {
	[self ensurePanel];
	if (!_engine->open(path.UTF8String)) {
		if (!quiet) [self alert:@"Could not open archive" info:[NSString stringWithUTF8String:_engine->error().c_str()]];
		return;
	}
	_displayPath = path;
	_archivePassword = nil;            // a different archive → forget the cached password
	_layers.clear();
	_layers.push_back({ std::string(path.UTF8String), std::string() });

	// Transparently descend single-stream compressors whose lone payload is itself
	// an archive: site.tar.gz → gzip{site.tar} → show the inner tar's files. We only
	// unwrap .gz/.bz2/.xz/.z (which always wrap exactly one file); a 1-entry .zip is
	// left as-is. Stop when the payload isn't itself an archive (e.g. data.json.gz).
	for (int guard = 0; guard < 6; guard++) {
		if (!isSingleStream(_engine->format())) break;
		if (_engine->entries().size() != 1 || _engine->entries()[0].isDir) break;
		const std::string childName = _engine->entries()[0].path;   // entry name in this layer
		NSString* tmpDir = [self newLayerTempDir];
		if (!_engine->extract({0}, tmpDir.UTF8String)) break;
		// The compressor wrote exactly one file into tmpDir; take it regardless of name.
		NSArray<NSString*>* kids = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:tmpDir error:nil];
		if (kids.count != 1) break;
		NSString* innerPath = [tmpDir stringByAppendingPathComponent:kids[0]];
		std::unique_ptr<NextZipEngine> probe(new NextZipEngine());
		if (!probe->open(innerPath.UTF8String)) break;              // plain file → keep the single entry
		_layers.back().second = childName;                          // remember for re-wrap on save
		_layers.push_back({ std::string(innerPath.UTF8String), std::string() });
		_engine = std::move(probe);
	}

	_archivePath = [NSString stringWithUTF8String:_layers.back().first.c_str()];
	freeTree(_root);
	_root = buildTree(_engine->entries());
	[self navigateTo:_root];
	[self.host nextZipRevealPanel];
}

// A fresh unique temp dir for one unwrapped layer (kept for the session so
// save-back can re-wrap even after navigating away).
- (NSString*)newLayerTempDir {
	NSString* base = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"NextZip"]
	                   stringByAppendingPathComponent:@"layers"];
	NSString* dir = [base stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	return dir;
}

// ── navigation ─────────────────────────────────────────────────────────────────
- (void)navigateTo:(FMNode*)node {
	if (!node) return;
	_cwd = node;
	// Changing folders starts unfiltered (so you see the whole folder you entered).
	_arcFilter = @"";
	_searchField.stringValue = @"";
	[self rebuildVisibleRows];
	// build ancestor chain root..cwd
	_ancestors.clear();
	for (FMNode* n = node; n; n = n->parent) _ancestors.insert(_ancestors.begin(), n);
	// breadcrumb items (small folder icon)
	NSImage* folder = [[NSImage imageNamed:NSImageNameFolder] copy];
	folder.size = NSMakeSize(13, 13);
	NSMutableArray* items = [NSMutableArray array];
	for (size_t i = 0; i < _ancestors.size(); i++) {
		NSPathControlItem* it = [[NSPathControlItem alloc] init];
		it.title = (i == 0) ? (_displayPath.lastPathComponent ?: _archivePath.lastPathComponent)
		                    : [NSString stringWithUTF8String:_ancestors[i]->name.c_str()];
		it.image = folder;
		[items addObject:it];
	}
	_breadcrumb.pathItems = items;
	// Standard-style NSPathControl draws via per-component cells that ignore the
	// control's font/controlSize — shrink each one explicitly so the bar is compact.
	for (NSPathComponentCell* c in _breadcrumb.pathComponentCells) {
		c.controlSize = NSControlSizeSmall;
		c.font = [NSFont systemFontOfSize:11];
	}
	[_table deselectAll:nil];
	[_table reloadData];
}
- (void)actBreadcrumb:(id)sender {
	NSPathControlItem* clicked = _breadcrumb.clickedPathItem;
	if (!clicked) return;
	NSUInteger idx = [_breadcrumb.pathItems indexOfObject:clicked];
	if (idx != NSNotFound && idx < _ancestors.size()) [self navigateTo:_ancestors[idx]];
}
- (void)actUp:(id)s { if (_cwd && _cwd->parent) [self navigateTo:_cwd->parent]; }

// ── table ───────────────────────────────────────────────────────────────────────
// Recompute the rows the table shows = the current folder's children passing the
// name filter (case-insensitive substring). Empty filter → all children, so the
// plugin (which never shows the search field) behaves exactly as before.
- (void)rebuildVisibleRows {
	_visibleRows.clear();
	if (!_cwd) return;
	NSString* f = _arcFilter ?: @"";
	if (f.length == 0) { _visibleRows = _cwd->children; return; }
	for (FMNode* c : _cwd->children) {
		NSString* name = [NSString stringWithUTF8String:c->name.c_str()];
		if (name && [name rangeOfString:f options:NSCaseInsensitiveSearch].location != NSNotFound)
			_visibleRows.push_back(c);
	}
}
- (FMNode*)nodeAtRow:(NSInteger)row {
	if (row < 0 || (size_t)row >= _visibleRows.size()) return nullptr;
	return _visibleRows[(size_t)row];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)t { return (NSInteger)_visibleRows.size(); }

// Live archive-pane name filter (app only). Fires on every keystroke and on the
// search field's clear button.
- (void)controlTextDidChange:(NSNotification*)note {
	if (note.object != _searchField) return;
	_arcFilter = [(_searchField.stringValue ?: @"") copy];
	[self rebuildVisibleRows];
	[_table reloadData];
}

- (NSView*)tableView:(NSTableView*)tv viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
	FMNode* n = [self nodeAtRow:row];
	NSString* cid = col.identifier;
	NSTableCellView* cell = [tv makeViewWithIdentifier:cid owner:self];
	if (!cell) {
		cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0,0,col.width,18)];
		cell.identifier = cid;
		NSTextField* tf = [NSTextField labelWithString:@""];
		tf.translatesAutoresizingMaskIntoConstraints = NO;
		tf.lineBreakMode = NSLineBreakByTruncatingTail; tf.font = [NSFont systemFontOfSize:12];
		[cell addSubview:tf]; cell.textField = tf;
		if ([cid isEqual:@"name"]) {
			NSImageView* iv = [[NSImageView alloc] initWithFrame:NSMakeRect(2,1,16,16)];
			iv.translatesAutoresizingMaskIntoConstraints = NO;
			[cell addSubview:iv]; cell.imageView = iv;
			[NSLayoutConstraint activateConstraints:@[
				[iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
				[iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
				[iv.widthAnchor constraintEqualToConstant:16], [iv.heightAnchor constraintEqualToConstant:16],
				[tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:5],
				[tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-3],
				[tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
			]];
		} else {
			[NSLayoutConstraint activateConstraints:@[
				[tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:3],
				[tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-3],
				[tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
			]];
		}
	}
	if (!n) { cell.textField.stringValue = @""; return cell; }
	const std::vector<NZEntry>& E = _engine->entries();
	const NZEntry* e = (n->entryIndex >= 0 && n->entryIndex < (int)E.size()) ? &E[n->entryIndex] : nullptr;
	if ([cid isEqual:@"name"]) {
		cell.textField.stringValue = [NSString stringWithUTF8String:n->name.c_str()];
		cell.imageView.image = n->isDir
			? [NSImage imageNamed:NSImageNameFolder]
			: [[NSWorkspace sharedWorkspace] iconForFileType:[NSString stringWithUTF8String:n->name.c_str()].pathExtension ?: @""];
	} else if (n->isDir || !e) {
		cell.textField.stringValue = @"";
	} else if ([cid isEqual:@"size"])   cell.textField.stringValue = humanSize(e->size);
	else if ([cid isEqual:@"pack"])     cell.textField.stringValue = humanSize(e->packSize);
	else if ([cid isEqual:@"crc"])      cell.textField.stringValue = e->hasCrc ? [NSString stringWithFormat:@"%08X", e->crc] : @"";
	else if ([cid isEqual:@"method"])   cell.textField.stringValue = [NSString stringWithUTF8String:e->method.c_str()];
	else if ([cid isEqual:@"modified"]) {
		if (e->mtime == 0) cell.textField.stringValue = @"";
		else {
			static NSDateFormatter* df = nil;
			if (!df) { df = [[NSDateFormatter alloc] init]; df.dateFormat = @"yyyy-MM-dd HH:mm"; }
			cell.textField.stringValue = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)e->mtime]];
		}
	}
	return cell;
}

- (void)onDoubleClick:(id)sender {
	FMNode* n = [self nodeAtRow:_table.clickedRow];
	if (!n) return;
	if (n->isDir) { [self navigateTo:n]; return; }
	[self openEntryInEditor:n];
}

// ── top pane: filesystem browser ────────────────────────────────────────────
- (NSArray<NSURL*>*)fsChildren:(NSURL*)url {
	if (!url) return _fsRoots;
	NSArray* cached = _fsChildrenCache[url];
	if (cached) return cached;
	NSArray<NSURL*>* items = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:url
		includingPropertiesForKeys:@[NSURLIsDirectoryKey]
		options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
	items = [items sortedArrayUsingComparator:^NSComparisonResult(NSURL* a, NSURL* b) {
		NSNumber* da = nil; [a getResourceValue:&da forKey:NSURLIsDirectoryKey error:nil];
		NSNumber* db = nil; [b getResourceValue:&db forKey:NSURLIsDirectoryKey error:nil];
		if (da.boolValue != db.boolValue) return da.boolValue ? NSOrderedAscending : NSOrderedDescending;
		return [a.lastPathComponent localizedCaseInsensitiveCompare:b.lastPathComponent];
	}];
	_fsChildrenCache[url] = items;
	return items;
}
- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(id)item { return (NSInteger)[self fsChildren:item].count; }
- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)i ofItem:(id)item { return [self fsChildren:item][(NSUInteger)i]; }
- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(id)item {
	NSNumber* d = nil; [(NSURL*)item getResourceValue:&d forKey:NSURLIsDirectoryKey error:nil]; return d.boolValue;
}
- (NSView*)outlineView:(NSOutlineView*)ov viewForTableColumn:(NSTableColumn*)col item:(id)item {
	NSURL* url = item;
	NSTableCellView* cell = [ov makeViewWithIdentifier:@"fscell" owner:self];
	if (!cell) {
		cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0,0,200,18)]; cell.identifier = @"fscell";
		NSImageView* iv = [[NSImageView alloc] initWithFrame:NSMakeRect(0,0,16,16)];
		iv.translatesAutoresizingMaskIntoConstraints = NO; [cell addSubview:iv]; cell.imageView = iv;
		NSTextField* tf = [NSTextField labelWithString:@""];
		tf.translatesAutoresizingMaskIntoConstraints = NO; tf.font = [NSFont systemFontOfSize:12];
		tf.lineBreakMode = NSLineBreakByTruncatingTail; [cell addSubview:tf]; cell.textField = tf;
		[NSLayoutConstraint activateConstraints:@[
			[iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
			[iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
			[iv.widthAnchor constraintEqualToConstant:16],[iv.heightAnchor constraintEqualToConstant:16],
			[tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:5],
			[tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-3],
			[tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
		]];
	}
	cell.textField.stringValue = url.lastPathComponent ?: url.path;
	cell.imageView.image = [[NSWorkspace sharedWorkspace] iconForFile:url.path];
	return cell;
}
// Single left-click on a file in the top pane → view its contents below.
- (void)outlineViewSelectionDidChange:(NSNotification*)note {
	if (note.object != _fsOutline) return;
	NSInteger row = _fsOutline.selectedRow; if (row < 0) return;
	NSURL* url = [_fsOutline itemAtRow:row];
	NSNumber* dir = nil; [url getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
	if (dir.boolValue) return;                                   // folder selection: do nothing
	if (_archivePath && [url.path isEqualToString:_archivePath]) return;  // already shown
	[self openArchiveAtPath:url.path quiet:YES];                 // non-archives are ignored quietly
}
// Double-click a folder in the top pane → expand/collapse.
- (void)onFsDoubleClick:(id)s {
	NSInteger row = _fsOutline.clickedRow; if (row < 0) return;
	NSURL* url = [_fsOutline itemAtRow:row];
	NSNumber* dir = nil; [url getResourceValue:&dir forKey:NSURLIsDirectoryKey error:nil];
	if (dir.boolValue) {
		if ([_fsOutline isItemExpanded:url]) [_fsOutline collapseItem:url]; else [_fsOutline expandItem:url];
	}
}

// ── password-aware extract / test ───────────────────────────────────────────
// Extract `indices` via `eng`, prompting for a password and retrying whenever the
// archive turns out to be encrypted (Windows 7-Zip behaviour). `initialPw` seeds
// the first attempt (e.g. the Extract dialog's optional field). Returns YES on
// success; shows an alert and returns NO on a genuine (non-password) failure;
// returns NO silently if the user cancels the password prompt.
- (BOOL)extractWithEngine:(NextZipEngine*)eng
                  indices:(const std::vector<uint32_t>&)indices
                       to:(NSString*)dest
                initialPw:(NSString*)initialPw
                  flatten:(BOOL)flatten
                overwrite:(int)overwrite
            eliminateRoot:(BOOL)elim
              archiveName:(NSString*)name
             usedPassword:(NSString* _Nullable * _Nullable)outPw {
	std::string pw = initialPw.length ? std::string(initialPw.UTF8String) : std::string();
	BOOL retried = (initialPw.length > 0);
	for (;;) {
		if (eng->extract(indices, dest.UTF8String, pw, flatten ? true : false, overwrite, elim ? true : false)) {
			if (outPw) *outPw = pw.empty() ? nil : [NSString stringWithUTF8String:pw.c_str()];
			return YES;
		}
		if (!eng->lastErrorNeedsPassword()) {
			[self alert:@"Extract failed" info:[NSString stringWithUTF8String:eng->error().c_str()]];
			return NO;
		}
		NSString* entered = [NextZipDialogs promptPasswordForArchive:name wrong:retried];
		if (entered == nil) return NO;           // user cancelled
		pw = std::string(entered.UTF8String);
		retried = YES;
	}
}

// As above, for "Test archive" (no files written). Returns YES if the archive
// verifies. On failure leaves eng->error() set for the caller to display; returns
// NO silently if the user cancels the password prompt.
- (BOOL)testWithEngine:(NextZipEngine*)eng
               indices:(const std::vector<uint32_t>&)indices
             initialPw:(NSString*)initialPw
           archiveName:(NSString*)name
          usedPassword:(NSString* _Nullable * _Nullable)outPw {
	std::string pw = initialPw.length ? std::string(initialPw.UTF8String) : std::string();
	BOOL retried = (initialPw.length > 0);
	for (;;) {
		if (eng->test(indices, pw)) {
			if (outPw) *outPw = pw.empty() ? nil : [NSString stringWithUTF8String:pw.c_str()];
			return YES;
		}
		if (!eng->lastErrorNeedsPassword()) return NO;   // genuine error → caller shows eng->error()
		NSString* entered = [NextZipDialogs promptPasswordForArchive:name wrong:retried];
		if (entered == nil) return NO;           // user cancelled
		pw = std::string(entered.UTF8String);
		retried = YES;
	}
}

// ── open a file from the archive in the editor (extract on the fly) ─────────────
- (void)openEntryInEditor:(FMNode*)n {
	if (n->entryIndex < 0) return;
	NSString* base = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"NextZip"]
	                   stringByAppendingPathComponent:_archivePath.lastPathComponent];
	std::vector<uint32_t> one{ (uint32_t)n->entryIndex };
	NSString* usedPw = nil;
	if (![self extractWithEngine:_engine.get() indices:one to:base initialPw:_archivePassword
	                     flatten:NO overwrite:0 eliminateRoot:NO archiveName:_archivePath.lastPathComponent
	                usedPassword:&usedPw]) {
		return;   // alert already shown, or user cancelled the password prompt
	}
	_archivePassword = usedPw;   // remember it so further files from this archive don't re-prompt
	NSString* rel  = [NSString stringWithUTF8String:_engine->entries()[n->entryIndex].path.c_str()];
	NSString* full = [base stringByAppendingPathComponent:rel];
	// Record this temp ↔ archive entry (incl. the nested-archive chain) FIRST, then
	// hand the host a pointer into the map node. NPPM_DOOPEN captures the raw const
	// char* and dereferences it on the NEXT run-loop turn (dispatch_async), so an
	// autoreleased -UTF8String buffer would already be freed → "The file name is
	// invalid." std::map node strings are stable (never relocated; outlive this call).
	OpenedTemp ot{ _engine->entries()[n->entryIndex].path, _layers };
	auto res = _openedTemps.insert_or_assign(std::string(full.UTF8String), std::move(ot));
	const char* stablePath = res.first->first.c_str();
	[self.host nextZipOpenExtractedFile:full stablePath:stablePath];
}

// ── save-back: editor saved a file we extracted → write it into the archive ──
// For a plain archive the chain is length 1 (update in place). For a nested one
// (e.g. .tar.gz) we update the innermost layer, then re-wrap outward: each parent
// compressor has its single payload replaced by the just-updated child file, so
// the change propagates all the way back to the real file on disk.
- (void)handleFileSaved:(NSString*)savedPath {
	if (!savedPath) return;
	auto it = _openedTemps.find(savedPath.UTF8String);
	if (it == _openedTemps.end()) return;                 // not one of ours
	const std::string entry = it->second.entryPath;
	const ArcChain& chain   = it->second.chain;
	if (chain.empty()) return;

	std::string err;
	bool ok = [self rewriteChain:chain entry:entry from:std::string(savedPath.UTF8String) error:err];
	if (!ok) { [self alert:@"Could not save back to archive" info:[NSString stringWithUTF8String:err.c_str()]]; return; }

	NSLog(@"[NextZip] saved '%s' back into %s", entry.c_str(), chain.front().first.c_str());
	// If what we just rewrote is the archive currently on screen, refresh the view.
	if (_archivePath && chain.back().first == std::string(_archivePath.UTF8String) && _root) {
		// Capture the current folder by PATH first: _cwd points into the tree we
		// are about to free, so navigating to it post-rebuild would dereference a
		// dangling node and the just-saved file would appear to vanish until the
		// next fresh open. Re-resolve the same path in the rebuilt tree instead.
		std::vector<std::string> cwdPath = _cwd ? nodePath(_cwd) : std::vector<std::string>();
		_engine->open(_archivePath.UTF8String);
		freeTree(_root); _root = buildTree(_engine->entries());
		FMNode* dest = findDirByPath(_root, cwdPath);
		[self navigateTo:dest ? dest : _root];
	}
}

// Write `entry` (= contents of `srcFile`) into chain.back(), then re-wrap each
// parent layer from inner to outer. Uses throwaway engines so it works regardless
// of the current on-screen archive.
- (BOOL)rewriteChain:(const ArcChain&)chain entry:(const std::string&)entry
                from:(const std::string&)srcFile error:(std::string&)err {
	// innermost: replace the edited entry
	{
		NextZipEngine inner;
		if (!inner.open(chain.back().first) || !inner.updateFile(entry, srcFile)) {
			err = inner.error().empty() ? "could not open innermost archive" : inner.error();
			return NO;
		}
	}
	// outward: each parent's lone payload becomes the just-updated child file
	for (long i = (long)chain.size() - 2; i >= 0; i--) {
		const std::string& parent     = chain[(size_t)i].first;
		const std::string& childName  = chain[(size_t)i].second;   // entry in parent that is the child
		const std::string& childFile  = chain[(size_t)i + 1].first;
		NextZipEngine e;
		if (!e.open(parent) || !e.updateFile(childName, childFile)) {
			err = e.error().empty() ? "could not re-wrap nested archive" : e.error();
			return NO;
		}
	}
	return YES;
}

// ═══════════════════════════════════════════════════════════════════════════
// TOP-PANE actions (filesystem selection): Add / Extract / Test / Delete / Info
// ═══════════════════════════════════════════════════════════════════════════
- (NSArray<NSString*>*)selectedFsPaths {
	NSMutableArray<NSString*>* out = [NSMutableArray array];
	NSIndexSet* rows = _fsOutline.selectedRowIndexes;
	[rows enumerateIndexesUsingBlock:^(NSUInteger r, BOOL* stop) {
		id item = [_fsOutline itemAtRow:(NSInteger)r];
		if ([item isKindOfClass:[NSURL class]]) {
			NSString* p = [(NSURL*)item path];
			if (p.length) [out addObject:p];
		}
	}];
	return out;
}
- (NSString*)singleFsSelection {
	NSArray<NSString*>* p = [self selectedFsPaths];
	return p.count == 1 ? p.firstObject : nil;
}
- (NSString*)singleArchiveSelection {
	NSString* p = [self singleFsSelection];
	return (p && !pathIsDir(p)) ? p : nil;     // a single regular file
}
// Clear the FS cache and reload, preserving the expanded rows where possible.
- (void)refreshFs {
	NSMutableArray<id>* expanded = [NSMutableArray array];
	for (NSInteger i = 0; i < _fsOutline.numberOfRows; i++) {
		id it = [_fsOutline itemAtRow:i];
		if ([_fsOutline isItemExpanded:it]) [expanded addObject:it];
	}
	[_fsChildrenCache removeAllObjects];
	[_fsOutline reloadData];
	for (id it in expanded) [_fsOutline expandItem:it];
}

- (void)fsAdd:(id)s {
	NSArray<NSString*>* inputs = [self selectedFsPaths];
	if (inputs.count == 0) { [self alert:@"Add to Archive" info:@"Select one or more files or folders first."]; return; }
	NZAddOptions* o = [NextZipDialogs runAddForInputs:inputs];
	if (!o) return;
	[self performAdd:o inputs:inputs];
}
- (void)fsAddQuick:(NSMenuItem*)item {
	NSString* fmt = [item.representedObject isKindOfClass:[NSString class]] ? item.representedObject : @"7z";
	NSArray<NSString*>* inputs = [self selectedFsPaths];
	if (inputs.count == 0) return;
	NSString* first = inputs.firstObject;
	NSString* dir = [first stringByDeletingLastPathComponent];
	NSString* base = inputs.count == 1 ? [[first lastPathComponent] stringByDeletingPathExtension]
	                                   : [dir lastPathComponent];
	if (base.length == 0) base = @"Archive";
	NSString* dest = [dir stringByAppendingPathComponent:[base stringByAppendingPathExtension:fmt]];
	NZAddOptions* o = [NZAddOptions new];
	o.archivePath = dest; o.format = fmt; o.level = 5; o.password = @""; o.encryptNames = NO; o.deleteAfter = NO;
	[self performAdd:o inputs:inputs];
}
- (void)performAdd:(NZAddOptions*)o inputs:(NSArray<NSString*>*)inputs {
	if (!o.archivePath.length || inputs.count == 0) return;
	if (o.createSFX)
		[self alert:@"Add to Archive" info:@"SFX archives aren’t supported in the macOS build — that option was ignored."];
	if (o.splitVolume.length)
		[self alert:@"Add to Archive" info:@"Splitting to volumes isn’t supported yet — that value was ignored."];
	if ([[NSFileManager defaultManager] fileExistsAtPath:o.archivePath]) {
		NSAlert* a = [[NSAlert alloc] init];
		a.messageText = @"Overwrite existing archive?";
		a.informativeText = [NSString stringWithFormat:@"%@\n\n(Adding into an existing archive is not yet supported.)", o.archivePath];
		[a addButtonWithTitle:@"Overwrite"]; [a addButtonWithTitle:@"Cancel"];
		if ([a runModal] != NSAlertFirstButtonReturn) return;
	}
	NextZipEngine::CompressOptions opt;
	opt.format        = o.format.UTF8String;
	opt.level         = o.level;
	opt.method        = o.method.length ? o.method.UTF8String : "";
	opt.dict          = o.dict;
	opt.wordSize      = o.wordSize;
	opt.solid         = o.solid.length ? o.solid.UTF8String : "";
	opt.threads       = o.threads;
	opt.memusePercent = o.memusePercent.length ? o.memusePercent.UTF8String : "";
	opt.password      = o.password.length ? o.password.UTF8String : "";
	opt.encMethod     = o.encMethod.length ? o.encMethod.UTF8String : "";
	opt.encryptNames  = o.encryptNames;
	opt.pathMode      = o.pathMode;
	opt.deleteAfter   = o.deleteAfter;
	opt.extraParams   = o.extraParams.length ? o.extraParams.UTF8String : "";
	std::vector<std::string> ins;
	for (NSString* p in inputs) if (p.length) ins.push_back(p.UTF8String);
	bool ok = _engine->compress(o.archivePath.UTF8String, opt, ins);
	if (ok) { [self refreshFs];
		[self alert:@"Add to Archive" info:[NSString stringWithFormat:@"Created:\n%@", o.archivePath]]; }
	else    [self alert:@"Add to Archive failed" info:[NSString stringWithUTF8String:_engine->error().c_str()]];
}

- (void)fsExtract:(id)s {
	NSString* a = [self singleArchiveSelection];
	if (!a) { [self alert:@"Extract" info:@"Select a single archive file first."]; return; }
	NZExtractOptions* o = [NextZipDialogs runExtractForArchive:a];
	if (!o) return;
	NSString* dest = o.destDir;
	if (o.intoSubfolder) dest = [dest stringByAppendingPathComponent:[[a lastPathComponent] stringByDeletingPathExtension]];
	[self extractArchive:a to:dest password:o.password flatten:(o.pathMode == 1)
	           overwrite:o.overwrite eliminateRoot:o.eliminateRoot];
}
- (void)fsExtractHere:(id)s {
	NSString* a = [self singleArchiveSelection]; if (!a) return;
	[self extractArchive:a to:[a stringByDeletingLastPathComponent] password:@"" flatten:NO overwrite:0 eliminateRoot:NO];
}
- (void)fsExtractToSub:(id)s {
	NSString* a = [self singleArchiveSelection]; if (!a) return;
	NSString* sub = [[a stringByDeletingLastPathComponent]
	                  stringByAppendingPathComponent:[[a lastPathComponent] stringByDeletingPathExtension]];
	[self extractArchive:a to:sub password:@"" flatten:NO overwrite:0 eliminateRoot:NO];
}
- (void)extractArchive:(NSString*)archivePath to:(NSString*)dest password:(NSString*)pw
               flatten:(BOOL)flatten overwrite:(int)overwrite eliminateRoot:(BOOL)elim {
	if (!archivePath.length || !dest.length) return;
	NextZipEngine eng;                                  // fresh engine — don't disturb the open view
	if (!eng.open(archivePath.UTF8String)) {
		[self alert:@"Extract failed" info:[NSString stringWithUTF8String:eng.error().c_str()]]; return;
	}
	std::vector<uint32_t> all;                          // empty = everything
	BOOL ok = [self extractWithEngine:&eng indices:all to:dest initialPw:pw
	                          flatten:flatten overwrite:overwrite eliminateRoot:elim
	                      archiveName:archivePath.lastPathComponent usedPassword:NULL];
	[self refreshFs];
	if (ok) [self alert:@"Extract" info:[NSString stringWithFormat:@"Extracted to:\n%@", dest]];
	// failure alert (or silent cancel) is handled inside the helper
}

- (void)fsTest:(id)s {
	NSString* a = [self singleArchiveSelection];
	if (!a) { [self alert:@"Test archive" info:@"Select a single archive file first."]; return; }
	NextZipEngine eng;
	if (!eng.open(a.UTF8String)) { [self alert:@"Test failed" info:[NSString stringWithUTF8String:eng.error().c_str()]]; return; }
	std::vector<uint32_t> none;
	BOOL ok = [self testWithEngine:&eng indices:none initialPw:nil archiveName:a.lastPathComponent usedPassword:NULL];
	unsigned long long files = 0, folders = 0, size = 0, packed = 0;
	for (const NZEntry& e : eng.entries()) { if (e.isDir) folders++; else { files++; size += e.size; packed += e.packSize; } }
	NSString* msg = [NSString stringWithFormat:
		@"Archive: %@\n\nArchives: 1\nPacked Size: %llu bytes\nFolders: %llu\nFiles: %llu\nSize: %llu bytes\n\n%@",
		a.lastPathComponent, packed, folders, files, size,
		ok ? @"There are no errors" : [NSString stringWithUTF8String:eng.error().c_str()]];
	[NextZipDialogs showInfoTitle:@"Testing" text:msg];
}

- (void)fsDelete:(id)s {
	NSArray<NSString*>* paths = [self selectedFsPaths];
	if (paths.count == 0) { [self alert:@"Delete" info:@"Select files or folders first."]; return; }
	NSAlert* a = [[NSAlert alloc] init];
	a.messageText = [NSString stringWithFormat:@"Move %lu item%@ to the Trash?",
	                 (unsigned long)paths.count, paths.count == 1 ? @"" : @"s"];
	a.informativeText = paths.count == 1 ? paths.firstObject : @"The selected items will be moved to the Trash.";
	[a addButtonWithTitle:@"Move to Trash"]; [a addButtonWithTitle:@"Cancel"];
	if ([a runModal] != NSAlertFirstButtonReturn) return;
	NSFileManager* fm = [NSFileManager defaultManager];
	for (NSString* p in paths) {
		NSError* err = nil;
		[fm trashItemAtURL:[NSURL fileURLWithPath:p] resultingItemURL:nil error:&err];
	}
	[self refreshFs];
}

- (void)fsInfo:(id)s          { [self computeChecksumForSelection:@"SHA256"]; }
- (void)fsChecksum:(NSMenuItem*)item {
	NSString* algo = [item.representedObject isKindOfClass:[NSString class]] ? item.representedObject : @"SHA256";
	[self computeChecksumForSelection:algo];
}
- (void)computeChecksumForSelection:(NSString*)algo {
	NSArray<NSString*>* paths = [self selectedFsPaths];
	if (paths.count == 0) { [self alert:@"Checksum" info:@"Select a file or folder first."]; return; }
	NSFileManager* fm = [NSFileManager defaultManager];
	unsigned long long folders = 0, files = 0, size = 0;
	NSString* singleFile = (paths.count == 1 && !pathIsDir(paths.firstObject)) ? paths.firstObject : nil;
	for (NSString* p in paths) {
		BOOL dir = NO; if (![fm fileExistsAtPath:p isDirectory:&dir]) continue;
		if (!dir) { files++; size += [[fm attributesOfItemAtPath:p error:nil][NSFileSize] unsignedLongLongValue]; continue; }
		folders++;
		NSDirectoryEnumerator* en = [fm enumeratorAtPath:p];
		for (NSString* sub in en) {
			NSString* full = [p stringByAppendingPathComponent:sub];
			BOOL d2 = NO; [fm fileExistsAtPath:full isDirectory:&d2];
			if (d2) folders++; else { files++; size += [[fm attributesOfItemAtPath:full error:nil][NSFileSize] unsignedLongLongValue]; }
		}
	}
	NSMutableString* msg = [NSMutableString string];
	[msg appendFormat:@"Folders: %llu\nFiles:   %llu\nSize:    %llu bytes\n", folders, files, size];
	if (singleFile) {
		[msg appendFormat:@"\nFile: %@\n", singleFile.lastPathComponent];
		NSMutableArray<NSString*>* algos = [NSMutableArray arrayWithObject:@"CRC32"];
		if (![algo isEqualToString:@"CRC32"]) [algos addObject:algo];
		for (NSString* a in algos) {
			std::string hex, err;
			if (NextZipEngine::checksumFile(singleFile.UTF8String, a.UTF8String, hex, err))
				[msg appendFormat:@"%-7@ %s\n", a, hex.c_str()];
			else
				[msg appendFormat:@"%-7@ (%s)\n", a, err.c_str()];
		}
	} else {
		[msg appendString:@"\n(Select a single file to compute its checksum.)"];
	}
	[NextZipDialogs showInfoTitle:@"Checksum information" text:msg];
}

// ═══════════════════════════════════════════════════════════════════════════
// BOTTOM-PANE extras: open-in-editor / delete-from-archive (menu)
// ═══════════════════════════════════════════════════════════════════════════
- (void)arcOpenInEditorMenu:(id)s {
	NSInteger row = _table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
	FMNode* n = [self nodeAtRow:row];
	if (n && !n->isDir && n->entryIndex >= 0) [self openEntryInEditor:n];
}
- (void)arcDelete:(id)s {
	if (!_root) return;
	std::vector<uint32_t> idx = [self selectedIndices];
	if (idx.empty()) { [self alert:@"Delete" info:@"Select entries to delete."]; return; }
	NSAlert* a = [[NSAlert alloc] init];
	a.messageText = [NSString stringWithFormat:@"Delete %lu item%@ from the archive?",
	                 (unsigned long)idx.size(), idx.size() == 1 ? @"" : @"s"];
	a.informativeText = @"This rewrites the archive without the selected entries.";
	[a addButtonWithTitle:@"Delete"]; [a addButtonWithTitle:@"Cancel"];
	if ([a runModal] != NSAlertFirstButtonReturn) return;
	if (!_engine->deleteEntries(idx)) {
		[self alert:@"Delete failed" info:[NSString stringWithUTF8String:_engine->error().c_str()]]; return;
	}
	// nested (.tar.gz): the inner temp changed → re-wrap outward to the real file.
	if (_layers.size() > 1) {
		std::string err;
		if (![self rewrapOutwardFromInner:err])
			[self alert:@"Saved inside, but couldn't update the outer archive" info:[NSString stringWithUTF8String:err.c_str()]];
	}
	freeTree(_root); _root = buildTree(_engine->entries());
	[self navigateTo:_root];
}
- (BOOL)rewrapOutwardFromInner:(std::string&)err {
	for (long i = (long)_layers.size() - 2; i >= 0; i--) {
		NextZipEngine e;
		if (!e.open(_layers[(size_t)i].first) || !e.updateFile(_layers[(size_t)i].second, _layers[(size_t)i + 1].first)) {
			err = e.error().empty() ? "re-wrap failed" : e.error(); return NO;
		}
	}
	return YES;
}

// ═══════════════════════════════════════════════════════════════════════════
// Right-click context menus (NSMenuDelegate)
// ═══════════════════════════════════════════════════════════════════════════
- (NSMenuItem*)addItem:(NSMenu*)menu title:(NSString*)title action:(SEL)sel {
	NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:title action:sel keyEquivalent:@""];
	it.target = self; [menu addItem:it]; return it;
}
- (void)menuNeedsUpdate:(NSMenu*)menu {
	[menu removeAllItems];
	if (menu == _fsMenu)       [self buildFsMenu:menu];
	else if (menu == _arcMenu) [self buildArcMenu:menu];
}
- (void)buildFsMenu:(NSMenu*)menu {
	NSInteger cr = _fsOutline.clickedRow;
	if (cr >= 0 && ![_fsOutline.selectedRowIndexes containsIndex:cr])
		[_fsOutline selectRowIndexes:[NSIndexSet indexSetWithIndex:cr] byExtendingSelection:NO];
	NSArray<NSString*>* sel = [self selectedFsPaths];
	if (sel.count == 0) return;
	BOOL single = (sel.count == 1);
	NSString* first = sel.firstObject;
	BOOL singleArchive = single && looksLikeArchive(first);
	NSString* nameNoExt = [[first lastPathComponent] stringByDeletingPathExtension];

	if (singleArchive) {
		[self addItem:menu title:@"Extract files…" action:@selector(fsExtract:)];
		[self addItem:menu title:@"Extract Here" action:@selector(fsExtractHere:)];
		[self addItem:menu title:[NSString stringWithFormat:@"Extract to \"%@/\"", nameNoExt] action:@selector(fsExtractToSub:)];
		[self addItem:menu title:@"Test archive" action:@selector(fsTest:)];
		[menu addItem:[NSMenuItem separatorItem]];
	}
	[self addItem:menu title:@"Add to archive…" action:@selector(fsAdd:)];
	NSString* qbase = single ? nameNoExt : [[first stringByDeletingLastPathComponent] lastPathComponent];
	if (qbase.length == 0) qbase = @"Archive";
	[self addItem:menu title:[NSString stringWithFormat:@"Add to \"%@.7z\"", qbase] action:@selector(fsAddQuick:)].representedObject = @"7z";
	[self addItem:menu title:[NSString stringWithFormat:@"Add to \"%@.zip\"", qbase] action:@selector(fsAddQuick:)].representedObject = @"zip";
	[menu addItem:[NSMenuItem separatorItem]];
	NSMenu* crc = [[NSMenu alloc] initWithTitle:@"CRC SHA"];
	for (NSString* alg in @[@"CRC32",@"MD5",@"SHA1",@"SHA256",@"SHA384",@"SHA512"]) {
		NSMenuItem* it = [[NSMenuItem alloc] initWithTitle:alg action:@selector(fsChecksum:) keyEquivalent:@""];
		it.target = self; it.representedObject = alg; [crc addItem:it];
	}
	NSMenuItem* crcItem = [[NSMenuItem alloc] initWithTitle:@"CRC SHA" action:nil keyEquivalent:@""];
	crcItem.submenu = crc; [menu addItem:crcItem];
}
- (void)buildArcMenu:(NSMenu*)menu {
	if (!_root) return;
	NSInteger cr = _table.clickedRow;
	if (cr >= 0 && ![_table.selectedRowIndexes containsIndex:cr])
		[_table selectRowIndexes:[NSIndexSet indexSetWithIndex:cr] byExtendingSelection:NO];
	FMNode* n = cr >= 0 ? [self nodeAtRow:cr] : nil;
	if (n && !n->isDir && n->entryIndex >= 0)
		[self addItem:menu title:@"Open in Editor" action:@selector(arcOpenInEditorMenu:)];
	[self addItem:menu title:@"Extract…" action:@selector(actExtract:)];
	[self addItem:menu title:@"Test" action:@selector(actTest:)];
	[self addItem:menu title:@"Info" action:@selector(actInfo:)];
	[menu addItem:[NSMenuItem separatorItem]];
	[self addItem:menu title:@"Delete from archive" action:@selector(arcDelete:)];
}

// ── toolbar: extract / test / info ──────────────────────────────────────────────
- (std::vector<uint32_t>)selectedIndices {
	__block std::vector<uint32_t> idx;
	NSIndexSet* rows = _table.selectedRowIndexes;
	[rows enumerateIndexesUsingBlock:^(NSUInteger row, BOOL* stop) {
		FMNode* n = [self nodeAtRow:(NSInteger)row];
		if (n) gatherEntryIndices(n, idx);
	}];
	return idx;
}

- (void)actOpen:(id)s { [self showOpenPanel]; }

- (void)actExtract:(id)s {
	if (!_root) return;
	std::vector<uint32_t> idx = [self selectedIndices];   // empty = extract everything
	NSOpenPanel* p = [NSOpenPanel openPanel];
	p.canChooseFiles = NO; p.canChooseDirectories = YES; p.prompt = @"Extract Here";
	if ([p runModal] != NSModalResponseOK || !p.URL) return;
	NSString* usedPw = nil;
	if ([self extractWithEngine:_engine.get() indices:idx to:p.URL.path initialPw:_archivePassword
	                    flatten:NO overwrite:0 eliminateRoot:NO archiveName:_archivePath.lastPathComponent
	               usedPassword:&usedPw]) {
		_archivePassword = usedPw;
		[self alert:@"Extraction complete" info:[NSString stringWithFormat:@"Extracted to:\n%@", p.URL.path]];
	}
}

- (void)actTest:(id)s {
	if (!_root) return;
	std::vector<uint32_t> idx = [self selectedIndices];
	NSString* usedPw = nil;
	if ([self testWithEngine:_engine.get() indices:idx initialPw:_archivePassword
	             archiveName:_archivePath.lastPathComponent usedPassword:&usedPw]) {
		_archivePassword = usedPw;
		[self alert:@"Test passed" info:@"No errors detected (CRCs OK)."];
	}
	else if (_engine->lastErrorNeedsPassword())
		return;   // user cancelled the password prompt — no nag
	else
		[self alert:@"Test failed" info:[NSString stringWithUTF8String:_engine->error().c_str()]];
}

- (void)actInfo:(id)s {
	FMNode* n = [self nodeAtRow:_table.selectedRow];
	if (!n) {
		NSString* nested = (_layers.size() > 1)
			? [NSString stringWithFormat:@"\n(unwrapped %lu nested layers)", (unsigned long)_layers.size() - 1] : @"";
		[self alert:@"NextZip" info:[NSString stringWithFormat:@"Archive: %@\nFormat: %s\nItems: %zu%@",
			_displayPath ?: _archivePath, _engine->format().c_str(), _engine->entries().size(), nested]]; return;
	}
	if (n->entryIndex < 0) { [self alert:@"Folder" info:[NSString stringWithUTF8String:n->name.c_str()]]; return; }
	const NZEntry& e = _engine->entries()[n->entryIndex];
	[self alert:[NSString stringWithUTF8String:e.path.c_str()]
	       info:[NSString stringWithFormat:@"Size: %llu\nPacked: %llu\nCRC: %@\nMethod: %s\nEncrypted: %@",
	             (unsigned long long)e.size, (unsigned long long)e.packSize,
	             e.hasCrc ? [NSString stringWithFormat:@"%08X", e.crc] : @"—",
	             e.method.c_str(), e.encrypted ? @"yes" : @"no"]];
}

- (void)showAbout {
	[self alert:@"NextZip" info:@"Archive manager for Nextpad++.\n\nEngine: 7-Zip (LGPL).\n"
	  "Extracts every format 7-Zip supports, including RAR / RAR5.\n"
	  "RAR is extraction-only (unRAR license — RAR archives cannot be created).\n\nGPL."];
}

- (void)alert:(NSString*)msg info:(NSString*)info {
	NSAlert* a = [[NSAlert alloc] init];
	a.messageText = msg; a.informativeText = info ?: @"";
	[a addButtonWithTitle:@"OK"];
	NSWindow* w = _panelView.window;
	if (w) [a beginSheetModalForWindow:w completionHandler:nil]; else [a runModal];
}
@end
