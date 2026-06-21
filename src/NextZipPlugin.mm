/*
 * NextZipPlugin.mm — Nextpad++ macOS plugin shell for NextZip.
 *
 * One of two shells over the shared NextZipController (the other is the
 * standalone NextZip.app). This shell owns the NppData, implements the
 * NextZipHost bridge (open-in-editor via NPPM_DOOPEN, current-file via
 * NPPM_GETFULLCURRENTPATH, the dock panel register/show/hide), and wires
 * NPPN_FILESAVED → save-back-into-archive.
 *
 * NextZip 2026 (GPL). Engine: 7-Zip (LGPL + unRAR restriction).
 */
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>
#include "NextZipController.h"
#include "NextZipHost.h"

static const char* PLUGIN_NAME = "NextZip";
static const int   NB_FUNC = 5;
static FuncItem    funcItem[NB_FUNC];
static NppData     nppData;

// ── host bridge: routes the controller's host calls to Nextpad++ ────────────────
@interface NextZipPluginHost : NSObject <NextZipHost>
@property (nonatomic, weak) NextZipController* controller;
@property (nonatomic)       void*             panelHandle;   // NPPM_DMM_REGISTERPANEL handle
@property (nonatomic)       BOOL              panelVisible;
- (void)togglePanel;
@end

@implementation NextZipPluginHost

// NPPM_DOOPEN dereferences the path on a later runloop turn, so it MUST be the
// controller's stable map pointer, not an autoreleased -UTF8String buffer.
- (void)nextZipOpenExtractedFile:(NSString*)displayPath stablePath:(const char*)stablePath {
	(void)displayPath;
	nppData._sendMessage(nppData._nppHandle, NPPM_DOOPEN, 0, (intptr_t)stablePath);
}

- (NSString*)nextZipCurrentFilePath {
	char path[4096]; path[0] = 0;
	nppData._sendMessage(nppData._nppHandle, NPPM_GETFULLCURRENTPATH, sizeof(path), (intptr_t)path);
	return path[0] ? [NSString stringWithUTF8String:path] : nil;
}

- (void)_registerIfNeeded {
	if (self.panelHandle) return;
	NSView* v = [self.controller panelView];
	if (v)   // host strong-retains the view
		self.panelHandle = (void*)nppData._sendMessage(nppData._nppHandle,
			NPPM_DMM_REGISTERPANEL, (uintptr_t)v, (intptr_t)"NextZip");
}

- (void)nextZipRevealPanel {
	[self _registerIfNeeded];
	if (self.panelHandle) nppData._sendMessage(nppData._nppHandle, NPPM_DMM_SHOWPANEL, (uintptr_t)self.panelHandle, 0);
	self.panelVisible = YES;
}

- (void)togglePanel {
	[self _registerIfNeeded];
	self.panelVisible = !self.panelVisible;
	if (self.panelHandle)
		nppData._sendMessage(nppData._nppHandle,
			self.panelVisible ? NPPM_DMM_SHOWPANEL : NPPM_DMM_HIDEPANEL,
			(uintptr_t)self.panelHandle, 0);
}
@end

static NextZipController* g_controller = nil;
static NextZipPluginHost* g_host       = nil;

static NextZipController* controller() {
	if (!g_controller) {
		g_controller = [[NextZipController alloc] init];
		g_host = [NextZipPluginHost new];
		g_host.controller = g_controller;
		g_controller.host = g_host;
		// Same Tahoe Liquid Glass capsule toolbar as the standalone app (macOS 26+;
		// falls back to textured buttons on older macOS). Set before -panelView.
		g_controller.usesGlassToolbars = YES;
	}
	return g_controller;
}

// ── menu commands ─────────────────────────────────────────────────────────────
static void cmdShowPanel()    { (void)controller(); [g_host togglePanel]; }
static void cmdOpenArchive()  { [controller() showOpenPanel]; }
static void cmdOpenCurrent()  { [controller() openCurrentEditorFile]; }
static void cmdAbout()        { [controller() showAbout]; }

// ── exports ───────────────────────────────────────────────────────────────────
extern "C" NPP_EXPORT void setInfo(NppData data) {
	nppData = data;
	strlcpy(funcItem[0]._itemName, "Show NextZip Archive Manager", NPP_MENU_ITEM_SIZE);
	funcItem[0]._pFunc = cmdShowPanel;   funcItem[0]._init2Check = false; funcItem[0]._pShKey = nullptr;
	strlcpy(funcItem[1]._itemName, "Open Archive…",            NPP_MENU_ITEM_SIZE);
	funcItem[1]._pFunc = cmdOpenArchive; funcItem[1]._init2Check = false; funcItem[1]._pShKey = nullptr;
	strlcpy(funcItem[2]._itemName, "Open Current File as Archive", NPP_MENU_ITEM_SIZE);
	funcItem[2]._pFunc = cmdOpenCurrent; funcItem[2]._init2Check = false; funcItem[2]._pShKey = nullptr;
	strlcpy(funcItem[3]._itemName, "—",                        NPP_MENU_ITEM_SIZE);
	funcItem[3]._pFunc = nullptr;        funcItem[3]._init2Check = false; funcItem[3]._pShKey = nullptr;
	strlcpy(funcItem[4]._itemName, "About NextZip",            NPP_MENU_ITEM_SIZE);
	funcItem[4]._pFunc = cmdAbout;       funcItem[4]._init2Check = false; funcItem[4]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char* getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem* getFuncsArray(int* nbF) { *nbF = NB_FUNC; return funcItem; }

extern "C" NPP_EXPORT void beNotified(SCNotification* n) {
	if (!n) return;
	if (n->nmhdr.code == NPPN_FILESAVED && g_controller) {
		// Map the saved buffer to its path; if it's a file we extracted from an
		// archive, write the edits back into the archive.
		char path[4096]; path[0] = 0;
		nppData._sendMessage(nppData._nppHandle, NPPM_GETFULLPATHFROMBUFFERID,
		                     (uintptr_t)n->nmhdr.idFrom, (intptr_t)path);
		if (path[0]) [g_controller handleFileSaved:[NSString stringWithUTF8String:path]];
	}
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) { return 1; }
