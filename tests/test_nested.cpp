// Headless validation of NextZip's nested .tar.gz descent + save-back re-wrap.
#include "SevenZipEngine.h"
#include <cstdio>
#include <string>
#include <dirent.h>

static std::string loneFile(const std::string& dir) {
	DIR* d = opendir(dir.c_str()); if (!d) return "";
	std::string only;
	for (dirent* e; (e = readdir(d)); ) {
		std::string n = e->d_name;
		if (n == "." || n == "..") continue;
		if (!only.empty()) { only = ""; break; }   // more than one → ambiguous
		only = n;
	}
	closedir(d);
	return only.empty() ? "" : dir + "/" + only;
}

static bool writeFile(const std::string& p, const char* s) {
	FILE* f = fopen(p.c_str(), "wb"); if (!f) return false;
	fputs(s, f); fclose(f); return true;
}

int main(int argc, char** argv) {
	if (argc < 5) { printf("usage: %s 7z.so site.tar.gz workdir entryToReplace\n", argv[0]); return 2; }
	std::string engine = argv[1], tgz = argv[2], work = argv[3], target = argv[4];

	// 1) open outer (gzip) — expect exactly one entry: the inner tar
	NextZipEngine gz; gz.setEnginePath(engine);
	if (!gz.open(tgz)) { printf("FAIL open outer: %s\n", gz.error().c_str()); return 1; }
	printf("outer: format=%s entries=%zu\n", gz.format().c_str(), gz.entries().size());
	if (gz.entries().size() != 1) { printf("FAIL: expected 1 entry in gzip\n"); return 1; }
	std::string childName = gz.entries()[0].path;
	printf("inner entry name='%s'\n", childName.c_str());

	// 2) extract the inner tar
	std::string innerDir = work + "/inner";
	if (!gz.extract({0}, innerDir)) { printf("FAIL extract inner: %s\n", gz.error().c_str()); return 1; }
	std::string innerTar = loneFile(innerDir);
	if (innerTar.empty()) { printf("FAIL: no lone file extracted\n"); return 1; }
	printf("inner tar=%s\n", innerTar.c_str());

	// 3) open inner tar, list files
	NextZipEngine tar; tar.setEnginePath(engine);
	if (!tar.open(innerTar)) { printf("FAIL open inner tar: %s\n", tar.error().c_str()); return 1; }
	printf("inner: format=%s entries=%zu\n", tar.format().c_str(), tar.entries().size());
	for (auto& e : tar.entries()) printf("   - %s (%llu)\n", e.path.c_str(), (unsigned long long)e.size);

	// 4) replace one file inside the tar
	std::string nf = work + "/new.txt";
	if (!writeFile(nf, "REPLACED-BY-TEST\n")) { printf("FAIL write newfile\n"); return 1; }
	if (!tar.updateFile(target, nf)) { printf("FAIL updateFile tar: %s\n", tar.error().c_str()); return 1; }
	printf("updated inner tar OK\n");

	// 5) re-wrap: replace the gzip's single payload with the updated inner tar
	NextZipEngine gz2; gz2.setEnginePath(engine);
	if (!gz2.open(tgz)) { printf("FAIL reopen outer: %s\n", gz2.error().c_str()); return 1; }
	if (!gz2.updateFile(childName, innerTar)) { printf("FAIL re-wrap gzip: %s\n", gz2.error().c_str()); return 1; }
	printf("re-wrapped gzip OK\n");
	printf("ALL-OK\n");
	return 0;
}
