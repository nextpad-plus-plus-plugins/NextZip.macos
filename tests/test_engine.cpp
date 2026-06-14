/* test_engine.cpp — headless check of NextZipEngine: open an archive + list it. */
#include "../src/SevenZipEngine.h"
#include <cstdio>

int main(int argc, char** argv) {
	if (argc < 2) { printf("usage: %s <archive> [path/to/7z.so]\n", argv[0]); return 2; }
	NextZipEngine eng;
	if (argc >= 3) eng.setEnginePath(argv[2]);
	if (!eng.open(argv[1])) { printf("OPEN FAILED: %s\n", eng.error().c_str()); return 1; }
	printf("format=%s  entries=%zu\n", eng.format().c_str(), eng.entries().size());
	size_t shown = 0;
	for (const NZEntry& e : eng.entries()) {
		if (shown++ >= 6) break;
		printf("  %-32s%s size=%llu pack=%llu crc=%s%08X method=%s\n",
		       e.path.c_str(), e.isDir ? " <dir>" : "      ",
		       (unsigned long long)e.size, (unsigned long long)e.packSize,
		       e.hasCrc ? "" : "(none)", e.hasCrc ? e.crc : 0, e.method.c_str());
	}
	// argv[1]=archive, argv[2]=7z.so, argv[3]=destDir → extract ALL to destDir
	if (argc >= 4) {
		printf("extracting all -> %s ...\n", argv[3]);
		if (!eng.extract({}, argv[3])) { printf("EXTRACT FAILED: %s\n", eng.error().c_str()); return 1; }
		printf("extract OK\n");
	}
	return 0;
}
