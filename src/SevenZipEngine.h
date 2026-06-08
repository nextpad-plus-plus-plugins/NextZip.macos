/*
 * SevenZipEngine.h — NineZip's C++ wrapper around the in-process 7-Zip engine
 * (the vendored 7z.so loaded via dlopen). Exposes a clean, SDK-free interface so
 * the ObjC++ UI never touches the COM/PROPVARIANT details.
 *
 * NineZip (Nextpad++ archive plugin) 2026. Engine: 7-Zip (LGPL + unRAR restriction).
 */
#ifndef NINEZIP_SEVENZIPENGINE_H
#define NINEZIP_SEVENZIPENGINE_H

#include <string>
#include <vector>
#include <cstdint>

// One archive entry (a row in the File-Manager list).
struct NZEntry {
	std::string path;        // full path inside the archive ("dir/sub/file.txt")
	uint64_t    size = 0;    // uncompressed size
	uint64_t    packSize = 0;// compressed size
	uint32_t    crc = 0;
	bool        hasCrc = false;
	bool        isDir = false;
	bool        encrypted = false;
	int64_t     mtime = 0;   // unix seconds (0 = unknown)
	std::string method;      // e.g. "LZMA2", "Deflate"
};

class NineZipEngine {
public:
	NineZipEngine();
	~NineZipEngine();

	// Explicitly point at the bundled 7z.so; if never called, open() auto-resolves
	// it next to the loaded plugin dylib (…/plugins/NineZip/7z.so).
	void        setEnginePath(const std::string& dylibPath);
	bool        loadEngine();           // dlopen + resolve CreateObject
	bool        isEngineLoaded() const;

	// Open an archive and enumerate entries. Returns true on success.
	bool        open(const std::string& archivePath);
	void        close();

	const std::vector<NZEntry>& entries() const { return m_entries; }
	const std::string& format() const { return m_format; }   // detected format name
	const std::string& error() const  { return m_error; }

private:
	NineZipEngine(const NineZipEngine&) = delete;
	NineZipEngine& operator=(const NineZipEngine&) = delete;
	struct Impl;
	Impl*                m_impl;
	std::vector<NZEntry> m_entries;
	std::string          m_enginePath, m_format, m_error;
};

#endif // NINEZIP_SEVENZIPENGINE_H
