/*
 * SevenZipEngine.h — NextZip's C++ wrapper around the in-process 7-Zip engine
 * (the vendored 7z.so loaded via dlopen). Exposes a clean, SDK-free interface so
 * the ObjC++ UI never touches the COM/PROPVARIANT details.
 *
 * NextZip (Nextpad++ archive plugin) 2026. Engine: 7-Zip (LGPL + unRAR restriction).
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

class NextZipEngine {
public:
	NextZipEngine();
	~NextZipEngine();

	// Explicitly point at the bundled 7z.so; if never called, open() auto-resolves
	// it next to the loaded plugin dylib (…/plugins/NextZip/7z.so).
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
	// overwrite: 0 = overwrite, 1 = skip existing, 2 = auto-rename.
	// eliminateRoot: if every extracted entry shares one top-level folder, drop it.
	bool extract(const std::vector<uint32_t>& indices, const std::string& destDir,
	             const std::string& password = std::string(), bool flatten = false,
	             int overwrite = 0, bool eliminateRoot = false);

	// Verify entries (decompress + CRC-check, no files written). indices empty = all.
	bool test(const std::vector<uint32_t>& indices, const std::string& password = std::string());

	// After the most recent extract()/test(): did it fail specifically because the
	// archive is encrypted and the password was missing or wrong? Lets the UI
	// prompt for a password and retry (Windows 7-Zip behaviour). Reset to false at
	// the start of every extract()/test() call.
	bool lastErrorNeedsPassword() const { return m_needPassword; }

	// Replace one entry's content with the bytes of localFile, rewriting the
	// archive in place (keeps all other entries). Only works for writable formats
	// (7z/zip/tar/gz/bz2/xz/wim) — returns false for read-only formats like RAR.
	// Re-opens the archive on success. This powers "save back to archive".
	bool updateFile(const std::string& entryPath, const std::string& localFile);

	// Full set of "Add to Archive" options, mapped 1:1 onto the 7-Zip property
	// names the Windows GUI uses (see UpdateGUI.cpp): x / 0|m / 0d|d / 0fb|fb /
	// s / mt / em / he / memuse. Empty/0 fields mean "let the engine default".
	struct CompressOptions {
		std::string format = "7z";   // 7z|zip|tar|gzip|bzip2|xz
		int         level = 5;       // 0,1,3,5,7,9
		std::string method;          // e.g. LZMA2/LZMA/PPMd/BZip2/Deflate ("" = default)
		uint64_t    dict = 0;        // dictionary size in bytes (0 = auto)
		uint32_t    wordSize = 0;    // word size / PPMd order (0 = auto)
		std::string solid;           // "" auto | "off" | "on" | "<bytes>b"
		int         threads = 0;     // CPU threads (0 = auto)
		std::string memusePercent;   // "" | "NN%"
		std::string password;        // "" = no encryption
		std::string encMethod;       // "" | "AES256" | "ZipCrypto"
		bool        encryptNames = false;  // 7z header encryption (he)
		int         pathMode = 0;    // 0 relative, 1 full, 2 absolute
		bool        deleteAfter = false;
		std::string extraParams;     // raw "name=value …" appended verbatim
	};

	// Create a NEW archive from filesystem paths (files and/or folders, recursed)
	// using the given options. Does NOT disturb any open archive.
	bool compress(const std::string& destPath, const CompressOptions& opt,
	              const std::vector<std::string>& inputs);

	// Remove entries (by index into entries()) from the currently-open archive,
	// rewriting it in place and re-opening. Writable formats only.
	bool deleteEntries(const std::vector<uint32_t>& indices);

	// Is the named format one NextZip can write/create? (7z/zip/tar/gz/bz2/xz/wim)
	static bool isWritableFormat(const std::string& format);

	// Compute a file checksum. algo ∈ CRC32/MD5/SHA1/SHA256/SHA384/SHA512.
	// Returns lowercase hex in hexOut. Pure helper — no engine needed.
	static bool checksumFile(const std::string& path, const std::string& algo,
	                         std::string& hexOut, std::string& err);

	const std::string& archivePath() const { return m_archivePath; }

private:
	NextZipEngine(const NextZipEngine&) = delete;
	NextZipEngine& operator=(const NextZipEngine&) = delete;
	struct Impl;
	Impl*                m_impl;
	std::vector<NZEntry> m_entries;
	std::string          m_enginePath, m_format, m_error, m_archivePath;
	bool                 m_needPassword = false;  // last extract/test failed on encryption
};

#endif // NINEZIP_SEVENZIPENGINE_H
