/*
 * SevenZipEngine.cpp — in-process 7-Zip wrapper for NineZip.
 *
 * Loads the vendored 7z.so via dlopen, resolves CreateObject, and drives the
 * IInArchive COM API to open + enumerate archives. Modeled on the SDK reference
 * client (deps/7zip/CPP/7zip/UI/Client7z/Client7z.cpp).
 *
 * Engine: 7-Zip (LGPL + unRAR restriction). RAR is EXTRACT-ONLY; NextZip/NineZip
 * must never offer "create RAR". See docs/20_format-matrix-and-rar.md.
 */
#include "SevenZipEngine.h"

#include "Common/MyWindows.h"
#include "Common/MyInitGuid.h"     // include ONCE in the program → defines IID_* GUIDs
#include "Common/MyCom.h"
#include "Common/StringConvert.h"
#include "7zip/Common/FileStreams.h"
#include "7zip/Archive/IArchive.h"
#include "7zip/PropID.h"
#include "Windows/PropVariant.h"

#include <dlfcn.h>
#include <cstring>

using namespace NWindows;

// ── engine entry point type ─────────────────────────────────────────────────
typedef Int32 (Z7_STDCALL *Func_CreateObject)(const GUID *clsid, const GUID *iid, void **out);

// ── format ids we try, signature-bearing first, signatureless (tar/cpio) last ─
namespace {
struct FmtId { Byte id; const char* name; };
const FmtId kFormats[] = {
	{0x07,"7z"}, {0x01,"zip"}, {0xCC,"rar5"}, {0x03,"rar"}, {0xEF,"gzip"},
	{0x02,"bzip2"}, {0x0C,"xz"}, {0x08,"cab"}, {0xE7,"iso"}, {0xE6,"wim"},
	{0x04,"arj"}, {0x05,"z"}, {0x06,"lzh"}, {0xEB,"rpm"}, {0xE4,"dmg"},
	{0xCB,"xar"}, {0xED,"cpio"}, {0xEE,"tar"},
};

GUID FormatGUID(Byte id) {
	GUID g;
	g.Data1 = 0x23170F69; g.Data2 = 0x40C1; g.Data3 = 0x278A;
	const unsigned char d4[8] = {0x10,0x00,0x00,0x01,0x10,id,0x00,0x00};
	memcpy(g.Data4, d4, 8);
	return g;
}

uint64_t PropToU64(const NCOM::CPropVariant& p) {
	switch (p.vt) {
		case VT_UI8: return (uint64_t)p.uhVal.QuadPart;
		case VT_UI4: return p.ulVal;
		case VT_UI2: return p.uiVal;
		case VT_UI1: return p.bVal;
		case VT_I8:  return (uint64_t)p.hVal.QuadPart;
		case VT_I4:  return (uint64_t)p.lVal;
		default:     return 0;
	}
}
bool PropToBool(const NCOM::CPropVariant& p) { return p.vt == VT_BOOL && p.boolVal != VARIANT_FALSE; }
std::string PropToUtf8(const NCOM::CPropVariant& p) {
	if (p.vt != VT_BSTR || !p.bstrVal) return std::string();
	UString us(p.bstrVal);
	AString a = UnicodeStringToMultiByte(us, CP_UTF8);
	return std::string(a.Ptr(), (size_t)a.Len());
}
int64_t FileTimeToUnix(const NCOM::CPropVariant& p) {
	if (p.vt != VT_FILETIME) return 0;
	uint64_t ft = ((uint64_t)p.filetime.dwHighDateTime << 32) | p.filetime.dwLowDateTime;
	if (ft == 0) return 0;
	return (int64_t)((ft - 116444736000000000ULL) / 10000000ULL);   // 1601→1970, 100ns→s
}
} // namespace

// ── pimpl ────────────────────────────────────────────────────────────────────
struct NineZipEngine::Impl {
	void*              dll = nullptr;
	Func_CreateObject  createObject = nullptr;
	CMyComPtr<IInArchive> arc;
};

NineZipEngine::NineZipEngine() : m_impl(new Impl) {}
NineZipEngine::~NineZipEngine() { close(); if (m_impl->dll) dlclose(m_impl->dll); delete m_impl; }

void NineZipEngine::setEnginePath(const std::string& p) { m_enginePath = p; }
bool NineZipEngine::isEngineLoaded() const { return m_impl->createObject != nullptr; }

// Resolve 7z.so next to this plugin's dylib if no explicit path was given.
static std::string defaultEnginePath() {
	Dl_info info;
	if (dladdr((void*)&defaultEnginePath, &info) && info.dli_fname) {
		std::string p(info.dli_fname);
		size_t slash = p.find_last_of('/');
		if (slash != std::string::npos) return p.substr(0, slash) + "/7z.so";
	}
	return "7z.so";
}

bool NineZipEngine::loadEngine() {
	if (m_impl->createObject) return true;
	std::string path = m_enginePath.empty() ? defaultEnginePath() : m_enginePath;
	m_impl->dll = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
	if (!m_impl->dll) { m_error = std::string("dlopen failed: ") + (dlerror() ?: "?"); return false; }
	m_impl->createObject = (Func_CreateObject)dlsym(m_impl->dll, "CreateObject");
	if (!m_impl->createObject) { m_error = "CreateObject not found in 7z.so"; return false; }
	return true;
}

void NineZipEngine::close() {
	if (m_impl->arc) { m_impl->arc->Close(); m_impl->arc.Release(); }
	m_entries.clear();
	m_format.clear();
}

bool NineZipEngine::open(const std::string& archivePath) {
	close();
	if (!loadEngine()) return false;

	const FString fpath = us2fs(GetUnicodeString(archivePath.c_str()));

	for (const FmtId& fmt : kFormats) {
		GUID clsid = FormatGUID(fmt.id);
		CMyComPtr<IInArchive> arc;
		if (m_impl->createObject(&clsid, &IID_IInArchive, (void**)&arc) != S_OK || !arc)
			continue;

		CInFileStream* fileSpec = new CInFileStream;
		CMyComPtr<IInStream> file = fileSpec;
		if (!fileSpec->Open(fpath)) { m_error = "cannot open file: " + archivePath; return false; }

		const UInt64 scanSize = 1 << 23;
		if (arc->Open(file, &scanSize, NULL) == S_OK) {
			m_impl->arc = arc;
			m_format = fmt.name;
			break;
		}
	}

	if (!m_impl->arc) { m_error = "not a recognized archive: " + archivePath; return false; }

	UInt32 num = 0;
	m_impl->arc->GetNumberOfItems(&num);
	m_entries.reserve(num);
	for (UInt32 i = 0; i < num; i++) {
		NZEntry e;
		NCOM::CPropVariant prop;
		if (m_impl->arc->GetProperty(i, kpidPath, &prop) == S_OK)      e.path = PropToUtf8(prop);
		if (m_impl->arc->GetProperty(i, kpidIsDir, &prop) == S_OK)     e.isDir = PropToBool(prop);
		if (m_impl->arc->GetProperty(i, kpidSize, &prop) == S_OK)      e.size = PropToU64(prop);
		if (m_impl->arc->GetProperty(i, kpidPackSize, &prop) == S_OK)  e.packSize = PropToU64(prop);
		if (m_impl->arc->GetProperty(i, kpidEncrypted, &prop) == S_OK) e.encrypted = PropToBool(prop);
		if (m_impl->arc->GetProperty(i, kpidMTime, &prop) == S_OK)     e.mtime = FileTimeToUnix(prop);
		if (m_impl->arc->GetProperty(i, kpidCRC, &prop) == S_OK && prop.vt == VT_UI4) { e.crc = prop.ulVal; e.hasCrc = true; }
		if (m_impl->arc->GetProperty(i, kpidMethod, &prop) == S_OK)    e.method = PropToUtf8(prop);
		m_entries.push_back(e);
	}
	return true;
}
