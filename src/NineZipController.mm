/*
 * NineZipController.mm — the NineZip archive File-Manager window.
 *
 * Browse an archive like a filesystem (folder tree built from entry paths),
 * breadcrumb + Up navigation, toolbar (Open/Up/Extract/Test/Info), and — the
 * point — open a file from the archive in the Nextpad++ editor by extracting it
 * on the fly to a temp folder, plus Extract/Test to disk.
 *
 * NineZip 2026 (GPL). Engine: 7-Zip (LGPL + unRAR restriction; RAR extract-only).
 */
#import <Cocoa/Cocoa.h>
#include "NineZipController.h"
#include "NppPluginInterfaceMac.h"
#include "SevenZipEngine.h"
#include <memory>
#include <vector>
#include <string>
#include <algorithm>
#include <functional>
#include <cctype>
#include <map>
#include <utility>

extern "C" NppData* NineZip_HostData();

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
} // namespace

// ─────────────────────────────────────────────────────────────────────────────
@interface NineZipController () <NSTableViewDataSource, NSTableViewDelegate,
                                NSOutlineViewDataSource, NSOutlineViewDelegate, NSWindowDelegate>
@end

@implementation NineZipController {
	const NppData*                 _npp;
	std::unique_ptr<NineZipEngine> _engine;
	FMNode*                        _root;
	FMNode*                        _cwd;
	std::vector<FMNode*>           _ancestors;   // root..cwd, parallel to breadcrumb items
	NSString*                      _archivePath;
	NSView*                        _panelView;     // dock-panel content (registered with the host)
	void*                          _panelHandle;   // NPPM_DMM_REGISTERPANEL handle
	BOOL                           _panelVisible;
	NSTableView*                   _table;
	NSPathControl*                 _breadcrumb;
	NSOutlineView*                 _fsOutline;       // top pane: filesystem browser
	NSArray<NSURL*>*               _fsRoots;
	NSMutableDictionary*           _fsChildrenCache; // NSURL → NSArray<NSURL*>
	// temp files opened in the editor → {archivePath, entryPath} for save-back
	std::map<std::string, std::pair<std::string,std::string>> _openedTemps;
}

static intptr_t hostMsg(uint32_t msg, uintptr_t w, intptr_t l) {
	NppData* d = NineZip_HostData();
	return d ? d->_sendMessage(d->_nppHandle, msg, w, l) : 0;
}

- (instancetype)initWithNpp:(const NppData*)npp {
	if ((self = [super init])) { _npp = npp; _engine.reset(new NineZipEngine()); _root = _cwd = nullptr; }
	return self;
}
- (void)dealloc { freeTree(_root); }

// ── window + toolbar ─────────────────────────────────────────────────────────
- (NSButton*)toolButton:(NSString*)tip symbol:(NSString*)sym action:(SEL)a {
	NSButton* b = [NSButton buttonWithTitle:@"" target:self action:a];
	NSImage* img = [NSImage imageWithSystemSymbolName:sym accessibilityDescription:tip];
	if (img) { b.image = img; b.imagePosition = NSImageOnly; }
	else     { b.title = tip; b.font = [NSFont systemFontOfSize:10]; }
	b.bezelStyle = NSBezelStyleTexturedRounded; b.toolTip = tip;
	b.translatesAutoresizingMaskIntoConstraints = NO;
	[b.widthAnchor constraintEqualToConstant:38].active = YES;
	return b;
}

- (void)ensurePanel {
	if (_panelView) return;
	NSView* v = [[NSView alloc] initWithFrame:NSMakeRect(0,0,760,560)];
	v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;   // host stretches us
	_panelView = v;

	// ── TOP pane: filesystem browser (click an archive → loads it below) ──
	NSScrollView* fsScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
	fsScroll.translatesAutoresizingMaskIntoConstraints = NO;
	fsScroll.hasVerticalScroller = YES; fsScroll.autohidesScrollers = YES;
	fsScroll.scrollerStyle = NSScrollerStyleOverlay; fsScroll.borderType = NSNoBorder;
	_fsOutline = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
	NSTableColumn* fc = [[NSTableColumn alloc] initWithIdentifier:@"fs"];
	fc.title = @"Disk"; [_fsOutline addTableColumn:fc]; _fsOutline.outlineTableColumn = fc;
	_fsOutline.headerView = nil; _fsOutline.dataSource = self; _fsOutline.delegate = self;
	_fsOutline.target = self; _fsOutline.doubleAction = @selector(onFsDoubleClick:);
	fsScroll.documentView = _fsOutline;
	_fsChildrenCache = [NSMutableDictionary dictionary];
	_fsRoots = @[ [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES],
	              [NSURL fileURLWithPath:@"/" isDirectory:YES] ];

	// ── BOTTOM pane: archive contents (toolbar + breadcrumb + table) ──
	NSView* arc = [[NSView alloc] initWithFrame:NSZeroRect];
	arc.translatesAutoresizingMaskIntoConstraints = NO;
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

	_breadcrumb = [[NSPathControl alloc] initWithFrame:NSZeroRect];
	_breadcrumb.translatesAutoresizingMaskIntoConstraints = NO;
	_breadcrumb.pathStyle = NSPathStyleStandard; _breadcrumb.editable = NO;
	_breadcrumb.controlSize = NSControlSizeSmall;                 // compact breadcrumb
	_breadcrumb.font = [NSFont systemFontOfSize:11];
	_breadcrumb.target = self; _breadcrumb.action = @selector(actBreadcrumb:);
	[arc addSubview:_breadcrumb];

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
	sc.documentView = _table;
	[arc addSubview:sc];
	[NSLayoutConstraint activateConstraints:@[
		[tb.topAnchor constraintEqualToAnchor:arc.topAnchor constant:6],
		[tb.leadingAnchor constraintEqualToAnchor:arc.leadingAnchor constant:8],
		[_breadcrumb.topAnchor constraintEqualToAnchor:tb.bottomAnchor constant:5],
		[_breadcrumb.leadingAnchor constraintEqualToAnchor:arc.leadingAnchor constant:8],
		[_breadcrumb.trailingAnchor constraintEqualToAnchor:arc.trailingAnchor constant:-8],
		[_breadcrumb.heightAnchor constraintEqualToConstant:16],
		[sc.topAnchor constraintEqualToAnchor:_breadcrumb.bottomAnchor constant:4],
		[sc.leadingAnchor constraintEqualToAnchor:arc.leadingAnchor],
		[sc.trailingAnchor constraintEqualToAnchor:arc.trailingAnchor],
		[sc.bottomAnchor constraintEqualToAnchor:arc.bottomAnchor],
	]];

	// ── split the panel vertically: FS browser on top, archive below ──
	NSSplitView* split = [[NSSplitView alloc] initWithFrame:v.bounds];
	split.translatesAutoresizingMaskIntoConstraints = NO;
	split.vertical = NO;                 // horizontal divider → stacked vertically
	split.dividerStyle = NSSplitViewDividerStyleThin;
	[split addArrangedSubview:fsScroll];
	[split addArrangedSubview:arc];
	[v addSubview:split];
	[NSLayoutConstraint activateConstraints:@[
		[split.topAnchor constraintEqualToAnchor:v.topAnchor],
		[split.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
		[split.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
		[split.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
	]];
	[v layoutSubtreeIfNeeded];
	[split setPosition:200 ofDividerAtIndex:0];   // ~200px filesystem pane on top
	[_fsOutline reloadData];

	// Register as a dockable panel (like AnalysePlugin/NppFTP); host strong-retains the view.
	_panelHandle = (void*)hostMsg(NPPM_DMM_REGISTERPANEL, (uintptr_t)v, (intptr_t)"NineZip");
}

- (void)show {
	[self ensurePanel];
	if (_panelHandle) hostMsg(NPPM_DMM_SHOWPANEL, (uintptr_t)_panelHandle, 0);
	_panelVisible = YES;
}
- (void)togglePanel {
	[self ensurePanel];
	_panelVisible = !_panelVisible;
	if (_panelHandle) hostMsg(_panelVisible ? NPPM_DMM_SHOWPANEL : NPPM_DMM_HIDEPANEL, (uintptr_t)_panelHandle, 0);
}

// ── open ──────────────────────────────────────────────────────────────────────
- (void)showOpenPanel {
	NSOpenPanel* p = [NSOpenPanel openPanel];
	p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = NO;
	if ([p runModal] == NSModalResponseOK && p.URL) [self openArchiveAtPath:p.URL.path];
}
- (void)openCurrentEditorFile {
	char path[4096]; path[0] = 0;
	NppData* d = NineZip_HostData();
	if (d) d->_sendMessage(d->_nppHandle, NPPM_GETFULLCURRENTPATH, sizeof(path), (intptr_t)path);
	if (path[0]) [self openArchiveAtPath:[NSString stringWithUTF8String:path]];
	else         [self showOpenPanel];
}

- (void)openArchiveAtPath:(NSString*)path { [self openArchiveAtPath:path quiet:NO]; }
- (void)openArchiveAtPath:(NSString*)path quiet:(BOOL)quiet {
	[self ensurePanel];
	if (!_engine->open(path.UTF8String)) {
		if (!quiet) [self alert:@"Could not open archive" info:[NSString stringWithUTF8String:_engine->error().c_str()]];
		return;
	}
	_archivePath = path;
	freeTree(_root);
	_root = buildTree(_engine->entries());
	[self navigateTo:_root];
	[self show];
}

// ── navigation ─────────────────────────────────────────────────────────────────
- (void)navigateTo:(FMNode*)node {
	if (!node) return;
	_cwd = node;
	// build ancestor chain root..cwd
	_ancestors.clear();
	for (FMNode* n = node; n; n = n->parent) _ancestors.insert(_ancestors.begin(), n);
	// breadcrumb items (small folder icon)
	NSImage* folder = [[NSImage imageNamed:NSImageNameFolder] copy];
	folder.size = NSMakeSize(13, 13);
	NSMutableArray* items = [NSMutableArray array];
	for (size_t i = 0; i < _ancestors.size(); i++) {
		NSPathControlItem* it = [[NSPathControlItem alloc] init];
		it.title = (i == 0) ? _archivePath.lastPathComponent
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
- (FMNode*)nodeAtRow:(NSInteger)row {
	if (!_cwd || row < 0 || (size_t)row >= _cwd->children.size()) return nullptr;
	return _cwd->children[(size_t)row];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView*)t { return _cwd ? (NSInteger)_cwd->children.size() : 0; }

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

// ── open a file from the archive in the editor (extract on the fly) ─────────────
- (void)openEntryInEditor:(FMNode*)n {
	if (n->entryIndex < 0) return;
	NSString* base = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"NineZip"]
	                   stringByAppendingPathComponent:_archivePath.lastPathComponent];
	if (!_engine->extract({(uint32_t)n->entryIndex}, base.UTF8String)) {
		[self alert:@"Could not extract file" info:[NSString stringWithUTF8String:_engine->error().c_str()]];
		return;
	}
	NSString* rel  = [NSString stringWithUTF8String:_engine->entries()[n->entryIndex].path.c_str()];
	NSString* full = [base stringByAppendingPathComponent:rel];
	// Record this temp ↔ archive entry FIRST, then hand the host a pointer into the
	// map node. NPPM_DOOPEN captures the raw const char* and dereferences it on the
	// NEXT run-loop turn (dispatch_async), so an autoreleased -UTF8String buffer would
	// already be freed → "The file name is invalid." std::map node strings are stable
	// (never relocated; outlive this call), which is exactly what the host needs.
	auto res = _openedTemps.insert_or_assign(std::string(full.UTF8String),
	               std::make_pair(std::string(_archivePath.UTF8String),
	                              _engine->entries()[n->entryIndex].path));
	const char* stablePath = res.first->first.c_str();
	NppData* d = NineZip_HostData();
	if (d) d->_sendMessage(d->_nppHandle, NPPM_DOOPEN, 0, (intptr_t)stablePath);
}

// ── save-back: editor saved a file we extracted → write it into the archive ──
- (void)handleFileSaved:(NSString*)savedPath {
	if (!savedPath) return;
	auto it = _openedTemps.find(savedPath.UTF8String);
	if (it == _openedTemps.end()) return;                 // not one of ours
	const std::string arc = it->second.first, entry = it->second.second;
	bool isCurrent = (_archivePath && arc == std::string(_archivePath.UTF8String) && _root);
	bool ok = false;
	if (isCurrent) {
		ok = _engine->updateFile(entry, savedPath.UTF8String);   // re-opens internally
		if (ok) { freeTree(_root); _root = buildTree(_engine->entries()); [self navigateTo:_root]; }
		else    [self alert:@"Could not save back to archive"
		               info:[NSString stringWithUTF8String:_engine->error().c_str()]];
	} else {
		NineZipEngine tmp;                                       // auto-resolves the engine dylib
		ok = tmp.open(arc) && tmp.updateFile(entry, savedPath.UTF8String);
		if (!ok) [self alert:@"Could not save back to archive"
		              info:[NSString stringWithUTF8String:tmp.error().c_str()]];
	}
	if (ok) NSLog(@"[NineZip] saved '%s' back into %s", entry.c_str(), arc.c_str());
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
	if (_engine->extract(idx, p.URL.path.UTF8String))
		[self alert:@"Extraction complete" info:[NSString stringWithFormat:@"Extracted to:\n%@", p.URL.path]];
	else
		[self alert:@"Extraction failed" info:[NSString stringWithUTF8String:_engine->error().c_str()]];
}

- (void)actTest:(id)s {
	if (!_root) return;
	std::vector<uint32_t> idx = [self selectedIndices];
	if (_engine->test(idx))
		[self alert:@"Test passed" info:@"No errors detected (CRCs OK)."];
	else
		[self alert:@"Test failed" info:[NSString stringWithUTF8String:_engine->error().c_str()]];
}

- (void)actInfo:(id)s {
	FMNode* n = [self nodeAtRow:_table.selectedRow];
	if (!n) { [self alert:@"NineZip" info:[NSString stringWithFormat:@"Archive: %@\nFormat: %s\nItems: %zu",
		_archivePath, _engine->format().c_str(), _engine->entries().size()]]; return; }
	if (n->entryIndex < 0) { [self alert:@"Folder" info:[NSString stringWithUTF8String:n->name.c_str()]]; return; }
	const NZEntry& e = _engine->entries()[n->entryIndex];
	[self alert:[NSString stringWithUTF8String:e.path.c_str()]
	       info:[NSString stringWithFormat:@"Size: %llu\nPacked: %llu\nCRC: %@\nMethod: %s\nEncrypted: %@",
	             (unsigned long long)e.size, (unsigned long long)e.packSize,
	             e.hasCrc ? [NSString stringWithFormat:@"%08X", e.crc] : @"—",
	             e.method.c_str(), e.encrypted ? @"yes" : @"no"]];
}

- (void)showAbout {
	[self alert:@"NineZip" info:@"Archive manager for Nextpad++.\n\nEngine: 7-Zip (LGPL).\n"
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
