/*
 * NextZipPlugin.mm — Nextpad++ macOS plugin entry for NextZip.
 * Five required exports + menu commands; owns the NextZipController.
 *
 * NextZip 2026 (GPL). Engine: 7-Zip (LGPL + unRAR restriction).
 */
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>
#include "NextZipController.h"

static const char* PLUGIN_NAME = "NextZip";
static const int   NB_FUNC = 5;
static FuncItem    funcItem[NB_FUNC];
static NppData     nppData;
static NextZipController* g_controller = nil;

extern "C" NppData* NextZip_HostData() { return &nppData; }

static NextZipController* controller() {
	if (!g_controller) g_controller = [[NextZipController alloc] initWithNpp:&nppData];
	return g_controller;
}

// ── menu commands ─────────────────────────────────────────────────────────────
static void cmdShowPanel()    { [controller() togglePanel]; }
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
