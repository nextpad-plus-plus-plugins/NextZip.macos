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
#include "7zip/IPassword.h"
#include "7zip/PropID.h"
#include "Windows/PropVariant.h"
#include "Windows/FileDir.h"
#include "Windows/FileName.h"

#include <dlfcn.h>
#include <cstring>
#include <cstdio>
#include <algorithm>
#include <sys/stat.h>
#include <dirent.h>
#include <unistd.h>
#include <set>
#include <CommonCrypto/CommonDigest.h>

using namespace NWindows;

// ── engine entry point type ─────────────────────────────────────────────────
typedef Int32 (Z7_STDCALL *Func_CreateObject)(const GUID *clsid, const GUID *iid, void **out);

// ── format ids we try, in detection order ────────────────────────────────────
// open() walks this list and the first handler whose Open() accepts the file
// wins, so strong-signature formats come first and the weak/signatureless ones
// (tar/cpio) come last. IDs verified against the vendored 7-Zip source
// (REGISTER_ARC). Filesystem/boot formats with loose signatures that over-match
// on ordinary files (fat/ntfs/mbr/gpt/split/elf) are deliberately omitted.
namespace {
struct FmtId { Byte id; const char* name; };
const FmtId kFormats[] = {
	// general archives
	{0x07,"7z"}, {0x01,"zip"}, {0xCC,"rar5"}, {0x03,"rar"},
	{0xEF,"gzip"}, {0x02,"bzip2"}, {0x0C,"xz"}, {0x05,"z"},
	{0x08,"cab"}, {0xE1,"xar"}, {0xEB,"rpm"}, {0xEC,"deb"},      // xar fixed (was 0xCB = GPT)
	{0x04,"arj"}, {0x06,"lzh"}, {0xE9,"chm"}, {0x09,"nsis"}, {0xE5,"compound"},
	// disk images / filesystems (specific magics → low false-positive)
	{0xE4,"dmg"}, {0xE3,"hfs"}, {0xC3,"apfs"}, {0xD2,"squashfs"}, {0xD3,"cramfs"},
	{0xC7,"ext"}, {0xE7,"iso"}, {0xE0,"udf"}, {0xE6,"wim"},
	{0xC4,"vhdx"}, {0xDC,"vhd"}, {0xC9,"vdi"}, {0xC8,"vmdk"}, {0xCA,"qcow"},
	// weak / no signature — keep LAST so they don't shadow the above
	{0xED,"cpio"}, {0xEE,"tar"},
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
	m_archivePath = archivePath;

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

// ── extract callback (writes requested entries to disk) ──────────────────────
namespace {
using namespace NWindows::NFile;

class CExtractCB Z7_final :
	public IArchiveExtractCallback,
	public ICryptoGetTextPassword,
	public CMyUnknownImp
{
	Z7_IFACES_IMP_UNK_2(IArchiveExtractCallback, ICryptoGetTextPassword)
	Z7_IFACE_COM7_IMP(IProgress)

	CMyComPtr<IInArchive> _arc;
	FString               _dir;        // normalized output dir prefix
	UString               _filePath;   // current item's path inside the archive
	UString               _fallback;   // name to use when an entry has no stored path
	bool                  _isDir = false;
	CMyComPtr<ISequentialOutStream> _out;
public:
	UString Password;
	bool    PasswordIsDefined = false;
	bool    Flatten = false;          // drop directory paths (extract basenames only)
	UInt64  NumErrors = 0;
	void Init(IInArchive* a, const FString& dir, const UString& fallback = UString()) {
		_arc = a; _dir = dir; NName::NormalizeDirPathPrefix(_dir); _fallback = fallback; NumErrors = 0;
	}
};

Z7_COM7F_IMF(CExtractCB::SetTotal(UInt64))            { return S_OK; }
Z7_COM7F_IMF(CExtractCB::SetCompleted(const UInt64*)) { return S_OK; }
Z7_COM7F_IMF(CExtractCB::PrepareOperation(Int32))     { return S_OK; }

Z7_COM7F_IMF(CExtractCB::GetStream(UInt32 index, ISequentialOutStream** outStream, Int32 askExtractMode)) {
	*outStream = NULL; _out.Release();
	{
		NCOM::CPropVariant prop;
		RINOK(_arc->GetProperty(index, kpidPath, &prop))
		_filePath = (prop.vt == VT_BSTR && prop.bstrVal) ? UString(prop.bstrVal) : UString();
	}
	// Single-stream compressors (.gz/.bz2/.xz from `tar czf`) often store no name —
	// fall back to a derived name so we still write a real file, not the dir itself.
	if (_filePath.IsEmpty()) _filePath = _fallback.IsEmpty() ? UString("payload") : _fallback;
	if (askExtractMode != NArchive::NExtract::NAskMode::kExtract) return S_OK;
	{
		NCOM::CPropVariant prop;
		RINOK(_arc->GetProperty(index, kpidIsDir, &prop))
		_isDir = (prop.vt == VT_BOOL && prop.boolVal != VARIANT_FALSE);
	}
	if (Flatten) {                                   // "No pathnames": basenames only
		if (_isDir) return S_OK;                     // skip directory entries entirely
		int s = _filePath.ReverseFind_PathSepar();
		if (s >= 0) _filePath = _filePath.Ptr((unsigned)(s + 1));
		if (_filePath.IsEmpty()) return S_OK;
	}
	const int slash = _filePath.ReverseFind_PathSepar();
	if (slash >= 0)
		NDir::CreateComplexDir(_dir + us2fs(_filePath.Left((unsigned)slash)));
	const FString full = _dir + us2fs(_filePath);
	if (_isDir) { NDir::CreateComplexDir(full); return S_OK; }

	COutFileStream* spec = new COutFileStream;
	CMyComPtr<ISequentialOutStream> outLoc(spec);
	if (!spec->Create_ALWAYS(full)) { NumErrors++; return E_ABORT; }
	_out = outLoc;
	*outStream = outLoc.Detach();
	return S_OK;
}

Z7_COM7F_IMF(CExtractCB::SetOperationResult(Int32 result)) {
	if (result != NArchive::NExtract::NOperationResult::kOK) NumErrors++;
	_out.Release();
	return S_OK;
}

Z7_COM7F_IMF(CExtractCB::CryptoGetTextPassword(BSTR* password)) {
	if (!PasswordIsDefined) return E_ABORT;   // caller can set a password later
	return StringToBstr(Password, password);
}
} // namespace

bool NineZipEngine::extract(const std::vector<uint32_t>& indices, const std::string& destDir,
                            const std::string& password, bool flatten) {
	if (!m_impl->arc) { m_error = "no archive open"; return false; }

	const FString fdest = us2fs(GetUnicodeString(destDir.c_str()));
	NWindows::NFile::NDir::CreateComplexDir(fdest);   // ensure destDir exists (top-level files)
	// Fallback name for nameless single-stream entries: archive basename minus its
	// last extension (site.tar.gz → site.tar).
	std::string baseName = m_archivePath;
	if (size_t s = baseName.find_last_of("/\\"); s != std::string::npos) baseName = baseName.substr(s + 1);
	if (size_t d = baseName.find_last_of('.'); d != std::string::npos && d > 0) baseName = baseName.substr(0, d);
	CExtractCB* cb = new CExtractCB;
	CMyComPtr<IArchiveExtractCallback> cbPtr(cb);
	cb->Init(m_impl->arc, fdest, GetUnicodeString(baseName.c_str()));
	cb->Flatten = flatten;
	if (!password.empty()) { cb->Password = GetUnicodeString(password.c_str()); cb->PasswordIsDefined = true; }

	std::vector<uint32_t> sorted(indices);
	std::sort(sorted.begin(), sorted.end());
	const UInt32* idx = sorted.empty() ? NULL : sorted.data();
	const UInt32  num = sorted.empty() ? (UInt32)(Int32)-1 : (UInt32)sorted.size();

	HRESULT hr = m_impl->arc->Extract(idx, num, BoolToInt(false), cbPtr);
	if (hr != S_OK)       { m_error = "extract failed"; return false; }
	if (cb->NumErrors)    { m_error = "extract completed with errors"; return false; }
	return true;
}

bool NineZipEngine::test(const std::vector<uint32_t>& indices, const std::string& password) {
	if (!m_impl->arc) { m_error = "no archive open"; return false; }
	CExtractCB* cb = new CExtractCB;
	CMyComPtr<IArchiveExtractCallback> cbPtr(cb);
	cb->Init(m_impl->arc, FString());
	if (!password.empty()) { cb->Password = GetUnicodeString(password.c_str()); cb->PasswordIsDefined = true; }
	std::vector<uint32_t> sorted(indices);
	std::sort(sorted.begin(), sorted.end());
	const UInt32* idx = sorted.empty() ? NULL : sorted.data();
	const UInt32  num = sorted.empty() ? (UInt32)(Int32)-1 : (UInt32)sorted.size();
	HRESULT hr = m_impl->arc->Extract(idx, num, BoolToInt(true), cbPtr);   // testMode = true
	if (hr != S_OK)    { m_error = "test failed"; return false; }
	if (cb->NumErrors) { m_error = "test found errors (bad CRC / corrupt)"; return false; }
	return true;
}

// ── update callback (replace one entry, copy the rest) ───────────────────────
namespace {
class CUpdateCB Z7_final :
	public IArchiveUpdateCallback,
	public CMyUnknownImp
{
	Z7_IFACES_IMP_UNK_1(IArchiveUpdateCallback)
	Z7_IFACE_COM7_IMP(IProgress)
	CMyComPtr<IInArchive> _arc;
	UInt32      _target = 0;       // index of the entry being replaced
	UString     _path;             // its path inside the archive
	std::string _local;            // local file (UTF-8) with the new content
public:
	UInt64 NumErrors = 0;
	void Init(IInArchive* a, UInt32 target, const UString& path, const std::string& local) {
		_arc = a; _target = target; _path = path; _local = local; NumErrors = 0;
	}
};

Z7_COM7F_IMF(CUpdateCB::SetTotal(UInt64))            { return S_OK; }
Z7_COM7F_IMF(CUpdateCB::SetCompleted(const UInt64*)) { return S_OK; }

Z7_COM7F_IMF(CUpdateCB::GetUpdateItemInfo(UInt32 index, Int32* newData, Int32* newProps, UInt32* indexInArchive)) {
	if (index == _target) { *newData = 1; *newProps = 1; *indexInArchive = (UInt32)(Int32)-1; }   // replace
	else                  { *newData = 0; *newProps = 0; *indexInArchive = index; }                // keep
	return S_OK;
}

Z7_COM7F_IMF(CUpdateCB::GetProperty(UInt32 index, PROPID propID, PROPVARIANT* value)) {
	NCOM::CPropVariant prop;
	if (index == _target) {
		switch (propID) {
			case kpidPath:  prop = _path.Ptr(); break;
			case kpidIsDir: prop = false; break;
			case kpidSize: {
				struct stat st; if (::stat(_local.c_str(), &st) == 0) prop = (UInt64)st.st_size;
				break; }
			case kpidAttrib: prop = (UInt32)0x20; break;   // FILE_ATTRIBUTE_ARCHIVE
			default: break;                                 // mtime etc. → handler default
		}
	}
	prop.Detach(value);
	return S_OK;
}

Z7_COM7F_IMF(CUpdateCB::GetStream(UInt32 index, ISequentialInStream** inStream)) {
	*inStream = NULL;
	if (index != _target) return S_OK;   // kept items: data copied from archive, no stream
	CInFileStream* s = new CInFileStream;
	CMyComPtr<ISequentialInStream> sp(s);
	if (!s->Open(us2fs(GetUnicodeString(_local.c_str())))) { NumErrors++; return E_FAIL; }
	*inStream = sp.Detach();
	return S_OK;
}

Z7_COM7F_IMF(CUpdateCB::SetOperationResult(Int32 op)) { if (op != 0) NumErrors++; return S_OK; }
} // namespace

bool NineZipEngine::updateFile(const std::string& entryPath, const std::string& localFile) {
	if (!m_impl->arc) { m_error = "no archive open"; return false; }
	CMyComPtr<IOutArchive> outArc;
	if (m_impl->arc->QueryInterface(IID_IOutArchive, (void**)&outArc) != S_OK || !outArc) {
		m_error = "this archive format is read-only — cannot save back (e.g. RAR)"; return false;
	}
	int target = -1;
	for (size_t i = 0; i < m_entries.size(); i++)
		if (!m_entries[i].isDir && m_entries[i].path == entryPath) { target = (int)i; break; }
	if (target < 0) { m_error = "entry not found: " + entryPath; return false; }

	const std::string tmp = m_archivePath + ".nztmp";
	{
		COutFileStream* outSpec = new COutFileStream;
		CMyComPtr<IOutStream> outStream(outSpec);
		if (!outSpec->Create_ALWAYS(us2fs(GetUnicodeString(tmp.c_str())))) {
			m_error = "cannot create temp output: " + tmp; return false;
		}
		CUpdateCB* cb = new CUpdateCB;
		CMyComPtr<IArchiveUpdateCallback> cbPtr(cb);
		cb->Init(m_impl->arc, (UInt32)target, GetUnicodeString(entryPath.c_str()), localFile);
		HRESULT hr = outArc->UpdateItems(outStream, (UInt32)m_entries.size(), cbPtr);
		outStream.Release();   // flush + close temp before we move it
		if (hr != S_OK || cb->NumErrors) {
			::remove(tmp.c_str());
			if (hr == E_NOTIMPL)
				m_error = "this archive can't be modified in place — it opened with warnings "
				          "(e.g. a macOS-created tar containing ._ resource files)";
			else {
				char buf[96]; snprintf(buf, sizeof buf, "archive update failed (0x%08X)", (unsigned)hr);
				m_error = buf;
			}
			return false;
		}
	}
	// Replace the original with the rebuilt archive, then re-open.
	std::string arcPath = m_archivePath;
	close();
	outArc.Release();
	if (::rename(tmp.c_str(), arcPath.c_str()) != 0) { ::remove(tmp.c_str()); m_error = "could not replace archive"; return false; }
	return open(arcPath);
}

// ── create-archive support ───────────────────────────────────────────────────
namespace {
struct CompItem {
	std::string localPath;   // file/dir on disk
	UString     arcPath;     // path to store inside the archive
	bool        isDir = false;
	UInt64      size = 0;
	int64_t     mtime = 0;   // unix seconds
};

// Recursively collect a filesystem path into compress items (dirs first per level).
void collectInto(const std::string& fsPath, const UString& arcName, std::vector<CompItem>& out) {
	struct stat st;
	if (::stat(fsPath.c_str(), &st) != 0) return;
	if (S_ISDIR(st.st_mode)) {
		CompItem d; d.localPath = fsPath; d.arcPath = arcName; d.isDir = true; d.mtime = st.st_mtime;
		out.push_back(d);
		DIR* dir = ::opendir(fsPath.c_str()); if (!dir) return;
		std::vector<std::string> names;
		for (struct dirent* e; (e = ::readdir(dir)); ) {
			std::string n = e->d_name;
			if (n == "." || n == "..") continue;
			names.push_back(n);
		}
		::closedir(dir);
		std::sort(names.begin(), names.end());
		for (const std::string& n : names)
			collectInto(fsPath + "/" + n, arcName + L"/" + GetUnicodeString(n.c_str()), out);
	} else if (S_ISREG(st.st_mode)) {
		CompItem f; f.localPath = fsPath; f.arcPath = arcName; f.isDir = false;
		f.size = (UInt64)st.st_size; f.mtime = st.st_mtime;
		out.push_back(f);
	}
}

static void UnixToFileTime(int64_t unixSec, FILETIME& ft) {
	uint64_t v = (uint64_t)((unixSec * 10000000LL) + 116444736000000000LL);
	ft.dwLowDateTime = (DWORD)(v & 0xFFFFFFFF);
	ft.dwHighDateTime = (DWORD)(v >> 32);
}

class CCreateCB Z7_final :
	public IArchiveUpdateCallback,
	public ICryptoGetTextPassword2,
	public CMyUnknownImp
{
	Z7_IFACES_IMP_UNK_2(IArchiveUpdateCallback, ICryptoGetTextPassword2)
	Z7_IFACE_COM7_IMP(IProgress)
	const std::vector<CompItem>* _items = nullptr;
public:
	UString Password;
	bool    PasswordIsDefined = false;
	UInt64  NumErrors = 0;
	void Init(const std::vector<CompItem>* items, const std::string& pw) {
		_items = items; NumErrors = 0;
		if (!pw.empty()) { Password = GetUnicodeString(pw.c_str()); PasswordIsDefined = true; }
	}
};

Z7_COM7F_IMF(CCreateCB::SetTotal(UInt64))            { return S_OK; }
Z7_COM7F_IMF(CCreateCB::SetCompleted(const UInt64*)) { return S_OK; }

Z7_COM7F_IMF(CCreateCB::GetUpdateItemInfo(UInt32, Int32* newData, Int32* newProps, UInt32* indexInArchive)) {
	// Every item is new with no source archive → newData=1, indexInArchive=-1.
	// (newData=0 + no source makes handlers read a non-existent source item and
	// crash.) Directories still report newData=1; we give them a VT_UI8 size of 0
	// in GetProperty, which is what strict handlers like tar require.
	*newData = 1; *newProps = 1; *indexInArchive = (UInt32)(Int32)-1;
	return S_OK;
}

Z7_COM7F_IMF(CCreateCB::GetProperty(UInt32 index, PROPID propID, PROPVARIANT* value)) {
	NCOM::CPropVariant prop;
	if (!_items || index >= _items->size()) { prop.Detach(value); return S_OK; }
	const CompItem& it = (*_items)[index];
	switch (propID) {
		case kpidPath:  prop = it.arcPath.Ptr(); break;
		case kpidIsDir: prop = it.isDir; break;
		case kpidSize:  prop = (UInt64)(it.isDir ? 0 : it.size); break;   // always VT_UI8 (tar requires it)
		case kpidAttrib: prop = (UInt32)(it.isDir ? 0x10 : 0x20); break;   // DIRECTORY / ARCHIVE
		case kpidMTime: { FILETIME ft; UnixToFileTime(it.mtime, ft); prop = ft; break; }
		default: break;
	}
	prop.Detach(value);
	return S_OK;
}

Z7_COM7F_IMF(CCreateCB::GetStream(UInt32 index, ISequentialInStream** inStream)) {
	*inStream = NULL;
	if (!_items || index >= _items->size()) return S_OK;
	const CompItem& it = (*_items)[index];
	if (it.isDir) return S_OK;                       // dirs have no data stream
	CInFileStream* s = new CInFileStream;
	CMyComPtr<ISequentialInStream> sp(s);
	if (!s->Open(us2fs(GetUnicodeString(it.localPath.c_str())))) { NumErrors++; return S_OK; }
	*inStream = sp.Detach();
	return S_OK;
}

Z7_COM7F_IMF(CCreateCB::SetOperationResult(Int32 op)) { if (op != 0) NumErrors++; return S_OK; }

Z7_COM7F_IMF(CCreateCB::CryptoGetTextPassword2(Int32* passwordIsDefined, BSTR* password)) {
	*passwordIsDefined = PasswordIsDefined ? 1 : 0;
	return PasswordIsDefined ? StringToBstr(Password, password) : S_OK;
}

// Map a NineZip format name → 7-Zip format byte id (0 = not writable here).
Byte writableFormatId(const std::string& fmt) {
	if (fmt == "7z")                        return 0x07;
	if (fmt == "zip")                       return 0x01;
	if (fmt == "tar")                       return 0xEE;
	if (fmt == "gzip" || fmt == "gz")       return 0xEF;
	if (fmt == "bzip2"|| fmt == "bz2")      return 0x02;
	if (fmt == "xz")                        return 0x0C;
	if (fmt == "wim")                       return 0xE6;
	return 0;
}
bool isSingleStreamFmt(const std::string& f) {
	return f=="gzip"||f=="gz"||f=="bzip2"||f=="bz2"||f=="xz";
}

static void removePathRecursive(const std::string& p) {
	struct stat st;
	if (::lstat(p.c_str(), &st) != 0) return;
	if (S_ISDIR(st.st_mode)) {
		DIR* d = ::opendir(p.c_str());
		if (d) {
			for (struct dirent* e; (e = ::readdir(d)); ) {
				std::string n = e->d_name;
				if (n == "." || n == "..") continue;
				removePathRecursive(p + "/" + n);
			}
			::closedir(d);
		}
		::rmdir(p.c_str());
	} else {
		::unlink(p.c_str());
	}
}
} // namespace

bool NineZipEngine::isWritableFormat(const std::string& format) {
	return writableFormatId(format) != 0;
}

bool NineZipEngine::compress(const std::string& destPath, const CompressOptions& opt,
                             const std::vector<std::string>& inputs) {
	m_error.clear();
	if (!loadEngine()) return false;
	const Byte fid = writableFormatId(opt.format);
	if (!fid) { m_error = "format is not writable: " + opt.format; return false; }
	if (inputs.empty()) { m_error = "no input files selected"; return false; }
	int level = opt.level; if (level < 0) level = 0; if (level > 9) level = 9;
	const bool is7z = (opt.format == "7z");
	const bool ppmd = (opt.method == "PPMd");

	// Collect items, honoring the path mode: relative = under the basename,
	// full/absolute = under the path with any leading '/' stripped (archives
	// cannot store a leading separator).
	std::vector<CompItem> items;
	for (std::string in : inputs) {
		while (in.size() > 1 && in.back() == '/') in.pop_back();
		std::string root;
		if (opt.pathMode == 0) {                                  // relative → basename
			root = in;
			if (size_t s = root.find_last_of('/'); s != std::string::npos) root = root.substr(s + 1);
		} else {                                                  // full / absolute
			root = in;
			while (!root.empty() && root.front() == '/') root.erase(root.begin());
		}
		if (root.empty()) { m_error = "invalid input path"; return false; }
		collectInto(in, GetUnicodeString(root.c_str()), items);
	}
	if (items.empty()) { m_error = "nothing to compress"; return false; }
	if (isSingleStreamFmt(opt.format)) {
		if (items.size() != 1 || items[0].isDir) {
			m_error = "gzip/bzip2/xz can hold only a single file — pick one file or use 7z/zip/tar";
			return false;
		}
	}

	GUID clsid = FormatGUID(fid);
	CMyComPtr<IOutArchive> outArc;
	if (m_impl->createObject(&clsid, &IID_IOutArchive, (void**)&outArc) != S_OK || !outArc) {
		m_error = "could not create archive object for " + opt.format; return false;
	}

	// Build the property list exactly as the 7-Zip GUI does (UpdateGUI.cpp).
	{
		CMyComPtr<ISetProperties> setp;
		if (outArc->QueryInterface(IID_ISetProperties, (void**)&setp) == S_OK && setp) {
			std::vector<UString> nameStore;
			std::vector<NCOM::CPropVariant> vals;
			auto addUInt = [&](const std::string& nm, UInt32 v) {
				nameStore.push_back(GetUnicodeString(nm.c_str()));
				NCOM::CPropVariant p; p = (UInt32)v; vals.push_back(p);
			};
			auto addStr = [&](const std::string& nm, const std::string& v) {
				nameStore.push_back(GetUnicodeString(nm.c_str()));
				NCOM::CPropVariant p; p = GetUnicodeString(v.c_str()).Ptr(); vals.push_back(p);
			};
			addUInt("x", (UInt32)level);
			if (level > 0) {                                      // store mode → no method/dict/word
				const std::string pfx = is7z ? "0" : "";
				if (!opt.method.empty()) addStr(is7z ? std::string("0") : std::string("m"), opt.method);
				if (opt.dict > 0)        addStr(pfx + (ppmd ? "mem" : "d"), std::to_string(opt.dict) + "b");
				if (opt.wordSize > 0)    addUInt(pfx + (ppmd ? "o" : "fb"), opt.wordSize);
			}
			if (!opt.solid.empty())          addStr("s", opt.solid);
			if (opt.threads > 0)             addUInt("mt", (UInt32)opt.threads);
			if (!opt.memusePercent.empty())  addStr("memuse", opt.memusePercent);
			if (!opt.encMethod.empty())      addStr("em", opt.encMethod);
			if (opt.encryptNames && is7z)    addStr("he", "on");
			// advanced "Parameters" box: whitespace-separated name=value tokens
			{
				std::string tok; std::string p = opt.extraParams;
				p.push_back(' ');
				for (char c : p) {
					if (c == ' ' || c == '\t' || c == '\n') {
						if (!tok.empty()) {
							size_t eq = tok.find('=');
							if (eq != std::string::npos) addStr(tok.substr(0, eq), tok.substr(eq + 1));
							else                         addStr(tok, "");
							tok.clear();
						}
					} else tok.push_back(c);
				}
			}
			std::vector<const wchar_t*> names; names.reserve(nameStore.size());
			for (const UString& u : nameStore) names.push_back(u.Ptr());
			if (!names.empty())
				setp->SetProperties(names.data(), (const PROPVARIANT*)vals.data(), (UInt32)names.size());
		}
	}

	const std::string tmp = destPath + ".nztmp";
	{
		COutFileStream* outSpec = new COutFileStream;
		CMyComPtr<IOutStream> outStream(outSpec);
		if (!outSpec->Create_ALWAYS(us2fs(GetUnicodeString(tmp.c_str())))) {
			m_error = "cannot create output file: " + tmp; return false;
		}
		CCreateCB* cb = new CCreateCB;
		CMyComPtr<IArchiveUpdateCallback> cbPtr(cb);
		cb->Init(&items, opt.password);
		HRESULT hr = outArc->UpdateItems(outStream, (UInt32)items.size(), cbPtr);
		outStream.Release();
		if (hr != S_OK || cb->NumErrors) {
			::remove(tmp.c_str());
			char buf[80]; snprintf(buf, sizeof buf, "compression failed (0x%08X)", (unsigned)hr);
			m_error = buf; return false;
		}
	}
	if (::rename(tmp.c_str(), destPath.c_str()) != 0) { ::remove(tmp.c_str()); m_error = "could not write archive: " + destPath; return false; }

	if (opt.deleteAfter) for (const std::string& in : inputs) removePathRecursive(in);
	return true;
}

// ── delete entries (rewrite archive without them) ────────────────────────────
namespace {
class CDeleteCB Z7_final :
	public IArchiveUpdateCallback,
	public CMyUnknownImp
{
	Z7_IFACES_IMP_UNK_1(IArchiveUpdateCallback)
	Z7_IFACE_COM7_IMP(IProgress)
	std::vector<UInt32> _map;   // new index → old index (kept items only)
public:
	UInt64 NumErrors = 0;
	void Init(std::vector<UInt32> keepMap) { _map = std::move(keepMap); NumErrors = 0; }
};
Z7_COM7F_IMF(CDeleteCB::SetTotal(UInt64))            { return S_OK; }
Z7_COM7F_IMF(CDeleteCB::SetCompleted(const UInt64*)) { return S_OK; }
Z7_COM7F_IMF(CDeleteCB::GetUpdateItemInfo(UInt32 index, Int32* newData, Int32* newProps, UInt32* indexInArchive)) {
	*newData = 0; *newProps = 0;
	*indexInArchive = (index < _map.size()) ? _map[index] : (UInt32)(Int32)-1;   // all kept items
	return S_OK;
}
Z7_COM7F_IMF(CDeleteCB::GetProperty(UInt32, PROPID, PROPVARIANT* value)) {
	NCOM::CPropVariant prop; prop.Detach(value); return S_OK;   // kept items: copied from source
}
Z7_COM7F_IMF(CDeleteCB::GetStream(UInt32, ISequentialInStream** inStream)) { *inStream = NULL; return S_OK; }
Z7_COM7F_IMF(CDeleteCB::SetOperationResult(Int32 op)) { if (op != 0) NumErrors++; return S_OK; }
} // namespace

bool NineZipEngine::deleteEntries(const std::vector<uint32_t>& indices) {
	if (!m_impl->arc) { m_error = "no archive open"; return false; }
	CMyComPtr<IOutArchive> outArc;
	if (m_impl->arc->QueryInterface(IID_IOutArchive, (void**)&outArc) != S_OK || !outArc) {
		m_error = "this archive format is read-only — cannot delete (e.g. RAR)"; return false;
	}
	std::set<uint32_t> del(indices.begin(), indices.end());
	std::vector<UInt32> keep;
	keep.reserve(m_entries.size());
	for (uint32_t i = 0; i < (uint32_t)m_entries.size(); i++)
		if (!del.count(i)) keep.push_back(i);
	if (keep.size() == m_entries.size()) { m_error = "nothing to delete"; return false; }

	const std::string tmp = m_archivePath + ".nztmp";
	{
		COutFileStream* outSpec = new COutFileStream;
		CMyComPtr<IOutStream> outStream(outSpec);
		if (!outSpec->Create_ALWAYS(us2fs(GetUnicodeString(tmp.c_str())))) { m_error = "cannot create temp output"; return false; }
		CDeleteCB* cb = new CDeleteCB;
		CMyComPtr<IArchiveUpdateCallback> cbPtr(cb);
		cb->Init(keep);
		HRESULT hr = outArc->UpdateItems(outStream, (UInt32)keep.size(), cbPtr);
		outStream.Release();
		if (hr != S_OK || cb->NumErrors) {
			::remove(tmp.c_str());
			if (hr == E_NOTIMPL) m_error = "this archive can't be modified (opened with warnings)";
			else { char b[64]; snprintf(b, sizeof b, "delete failed (0x%08X)", (unsigned)hr); m_error = b; }
			return false;
		}
	}
	std::string arcPath = m_archivePath;
	close(); outArc.Release();
	if (::rename(tmp.c_str(), arcPath.c_str()) != 0) { ::remove(tmp.c_str()); m_error = "could not replace archive"; return false; }
	return open(arcPath);
}

// ── checksums (CommonCrypto + table CRC32) ───────────────────────────────────
bool NineZipEngine::checksumFile(const std::string& path, const std::string& algo,
                                 std::string& hexOut, std::string& err) {
	FILE* f = ::fopen(path.c_str(), "rb");
	if (!f) { err = "cannot open: " + path; return false; }
	std::vector<unsigned char> buf(1 << 16);
	size_t r;
	auto toHex = [](const unsigned char* d, size_t n, bool upper) {
		static const char* lo = "0123456789abcdef"; static const char* hi = "0123456789ABCDEF";
		const char* t = upper ? hi : lo; std::string s; s.reserve(n * 2);
		for (size_t i = 0; i < n; i++) { s.push_back(t[d[i] >> 4]); s.push_back(t[d[i] & 0xF]); }
		return s;
	};

	if (algo == "CRC32") {
		static uint32_t T[256]; static bool init = false;
		if (!init) { for (uint32_t i = 0; i < 256; i++) { uint32_t c = i; for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1); T[i] = c; } init = true; }
		uint32_t crc = 0xFFFFFFFFu;
		while ((r = ::fread(buf.data(), 1, buf.size(), f)) > 0)
			for (size_t i = 0; i < r; i++) crc = T[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
		crc ^= 0xFFFFFFFFu;
		unsigned char b[4] = { (unsigned char)(crc >> 24), (unsigned char)(crc >> 16), (unsigned char)(crc >> 8), (unsigned char)crc };
		hexOut = toHex(b, 4, true);
		::fclose(f); return true;
	}
#define NZ_HASH(NAME, CTX, INIT, UPD, FIN, LEN)                                  \
	if (algo == NAME) {                                                          \
		CTX c; INIT(&c);                                                         \
		while ((r = ::fread(buf.data(), 1, buf.size(), f)) > 0) UPD(&c, buf.data(), (CC_LONG)r); \
		unsigned char d[LEN]; FIN(d, &c);                                        \
		hexOut = toHex(d, LEN, false); ::fclose(f); return true;                 \
	}
	NZ_HASH("MD5",    CC_MD5_CTX,    CC_MD5_Init,    CC_MD5_Update,    CC_MD5_Final,    CC_MD5_DIGEST_LENGTH)
	NZ_HASH("SHA1",   CC_SHA1_CTX,   CC_SHA1_Init,   CC_SHA1_Update,   CC_SHA1_Final,   CC_SHA1_DIGEST_LENGTH)
	NZ_HASH("SHA256", CC_SHA256_CTX, CC_SHA256_Init, CC_SHA256_Update, CC_SHA256_Final, CC_SHA256_DIGEST_LENGTH)
	NZ_HASH("SHA384", CC_SHA512_CTX, CC_SHA384_Init, CC_SHA384_Update, CC_SHA384_Final, CC_SHA384_DIGEST_LENGTH)
	NZ_HASH("SHA512", CC_SHA512_CTX, CC_SHA512_Init, CC_SHA512_Update, CC_SHA512_Final, CC_SHA512_DIGEST_LENGTH)
#undef NZ_HASH
	::fclose(f);
	err = "unsupported checksum: " + algo;
	return false;
}
