/*
 * NineZipPlugin.mm — Nextpad++ macOS plugin entry for NineZip.
 * Five required exports + menu commands; owns the NineZipController.
 *
 * NineZip 2026 (GPL). Engine: 7-Zip (LGPL + unRAR restriction).
 */
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>
#include "NineZipController.h"

static const char* PLUGIN_NAME = "NineZip";
static const int   NB_FUNC = 4;
static FuncItem    funcItem[NB_FUNC];
static NppData     nppData;
static NineZipController* g_controller = nil;

extern "C" NppData* NineZip_HostData() { return &nppData; }

static NineZipController* controller() {
	if (!g_controller) g_controller = [[NineZipController alloc] initWithNpp:&nppData];
	return g_controller;
}

// ── menu commands ─────────────────────────────────────────────────────────────
static void cmdOpenArchive()  { [controller() showOpenPanel]; }
static void cmdOpenCurrent()  { [controller() openCurrentEditorFile]; }
static void cmdAbout()        { [controller() showAbout]; }

// ── exports ───────────────────────────────────────────────────────────────────
extern "C" NPP_EXPORT void setInfo(NppData data) {
	nppData = data;
	strlcpy(funcItem[0]._itemName, "Open Archive…",            NPP_MENU_ITEM_SIZE);
	funcItem[0]._pFunc = cmdOpenArchive; funcItem[0]._init2Check = false; funcItem[0]._pShKey = nullptr;
	strlcpy(funcItem[1]._itemName, "Open Current File as Archive", NPP_MENU_ITEM_SIZE);
	funcItem[1]._pFunc = cmdOpenCurrent; funcItem[1]._init2Check = false; funcItem[1]._pShKey = nullptr;
	strlcpy(funcItem[2]._itemName, "—",                        NPP_MENU_ITEM_SIZE);
	funcItem[2]._pFunc = nullptr;        funcItem[2]._init2Check = false; funcItem[2]._pShKey = nullptr;
	strlcpy(funcItem[3]._itemName, "About NineZip",            NPP_MENU_ITEM_SIZE);
	funcItem[3]._pFunc = cmdAbout;       funcItem[3]._init2Check = false; funcItem[3]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char* getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem* getFuncsArray(int* nbF) { *nbF = NB_FUNC; return funcItem; }

extern "C" NPP_EXPORT void beNotified(SCNotification* n) { (void)n; }

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) { return 1; }
