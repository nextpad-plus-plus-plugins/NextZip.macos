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

	// Extract the given entry indices (empty = all) into destDir, recreating each
	// entry's relative path. Returns true on success. Optional password for
	// encrypted archives. Used by the "Extract" command and by extract-to-temp
	// (open a file from the archive in the editor).
	bool extract(const std::vector<uint32_t>& indices, const std::string& destDir,
	             const std::string& password = std::string(), bool flatten = false);

	// Verify entries (decompress + CRC-check, no files written). indices empty = all.
	bool test(const std::vector<uint32_t>& indices, const std::string& password = std::string());

	// Replace one entry's content with the bytes of localFile, rewriting the
	// archive in place (keeps all other entries). Only works for writable formats
	// (7z/zip/tar/gz/bz2/xz/wim) — returns false for read-only formats like RAR.
	// Re-opens the archive on success. This powers "save back to archive".
	bool updateFile(const std::string& entryPath, const std::string& localFile);

	// Create a new archive from filesystem paths (files and/or folders, recursed).
	// format ∈ 7z/zip/tar/gz/bz2/xz/wim; level 0..9 (0 = store). password empty =
	// no encryption; encryptNames applies to 7z only; deleteAfter removes the
	// inputs after a successful compress. Does NOT disturb any open archive.
	bool compress(const std::string& destPath, const std::string& format, int level,
	              const std::string& password, bool encryptNames,
	              const std::vector<std::string>& inputs, bool deleteAfter);

	// Remove entries (by index into entries()) from the currently-open archive,
	// rewriting it in place and re-opening. Writable formats only.
	bool deleteEntries(const std::vector<uint32_t>& indices);

	// Is the named format one NineZip can write/create? (7z/zip/tar/gz/bz2/xz/wim)
	static bool isWritableFormat(const std::string& format);

	// Compute a file checksum. algo ∈ CRC32/MD5/SHA1/SHA256/SHA384/SHA512.
	// Returns lowercase hex in hexOut. Pure helper — no engine needed.
	static bool checksumFile(const std::string& path, const std::string& algo,
	                         std::string& hexOut, std::string& err);

	const std::string& archivePath() const { return m_archivePath; }

private:
	NineZipEngine(const NineZipEngine&) = delete;
	NineZipEngine& operator=(const NineZipEngine&) = delete;
	struct Impl;
	Impl*                m_impl;
	std::vector<NZEntry> m_entries;
	std::string          m_enginePath, m_format, m_error, m_archivePath;
};

#endif // NINEZIP_SEVENZIPENGINE_H
