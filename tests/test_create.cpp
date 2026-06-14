// Headless validation: compress (zip/7z), delete entry, checksum.
#include "SevenZipEngine.h"
#include <cstdio>
#include <string>
#include <vector>

int main(int argc, char** argv) {
	if (argc < 4) { printf("usage: %s 7z.so inputDir outDir\n", argv[0]); return 2; }
	std::string engine = argv[1], in = argv[2], out = argv[3];

	// 1) compress into zip and 7z
	for (std::string fmt : {std::string("zip"), std::string("7z"), std::string("tar")}) {
		NextZipEngine e; e.setEnginePath(engine);
		std::string dest = out + "/out." + fmt;
		std::vector<std::string> inputs = { in };
		NextZipEngine::CompressOptions o; o.format = fmt; o.level = 5;
		if (!e.compress(dest, o, inputs)) {
			printf("FAIL compress %s: %s\n", fmt.c_str(), e.error().c_str()); return 1;
		}
		NextZipEngine r; r.setEnginePath(engine);
		if (!r.open(dest)) { printf("FAIL reopen %s: %s\n", fmt.c_str(), r.error().c_str()); return 1; }
		printf("compress %-3s OK → %zu entries, format=%s\n", fmt.c_str(), r.entries().size(), r.format().c_str());
	}

	// 2) delete one entry from the zip
	{
		NextZipEngine e; e.setEnginePath(engine);
		std::string dest = out + "/out.zip";
		if (!e.open(dest)) { printf("FAIL open zip: %s\n", e.error().c_str()); return 1; }
		size_t before = e.entries().size();
		// find a non-dir entry to delete
		int idx = -1;
		for (size_t i = 0; i < e.entries().size(); i++) if (!e.entries()[i].isDir) { idx = (int)i; break; }
		if (idx < 0) { printf("FAIL: no file entry to delete\n"); return 1; }
		std::string victim = e.entries()[idx].path;
		if (!e.deleteEntries({(uint32_t)idx})) { printf("FAIL delete: %s\n", e.error().c_str()); return 1; }
		size_t after = e.entries().size();
		printf("delete OK: '%s' removed, %zu → %zu\n", victim.c_str(), before, after);
		for (auto& en : e.entries()) if (en.path == victim && !en.isDir) { printf("FAIL: victim still present\n"); return 1; }
	}

	// 3) checksum a known file
	{
		std::string err, hex;
		std::string probe = out + "/out.7z";
		for (std::string algo : {std::string("CRC32"), std::string("MD5"), std::string("SHA1"), std::string("SHA256")}) {
			if (!NextZipEngine::checksumFile(probe, algo, hex, err)) { printf("FAIL checksum %s: %s\n", algo.c_str(), err.c_str()); return 1; }
			printf("%-7s %s\n", algo.c_str(), hex.c_str());
		}
	}
	printf("ALL-OK\n");
	return 0;
}
