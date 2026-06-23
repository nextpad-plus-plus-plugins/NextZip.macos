// Headless validation for NextZipEngine::addPaths (Feature #3 — drag-in-to-add).
// Covers: add a file, add a folder (recursed), add into a subfolder prefix,
// path collision (must REPLACE in place, not duplicate), and the single-stream
// refusal. Run: test_add <7z.so> <writable outDir>
#include "SevenZipEngine.h"
#include <cstdio>
#include <string>
#include <vector>
#include <sys/stat.h>

static void writeFile(const std::string& p, const std::string& c) {
	FILE* f = fopen(p.c_str(), "wb"); if (f) { fwrite(c.data(), 1, c.size(), f); fclose(f); }
}
static int countPath(NextZipEngine& e, const std::string& path) {
	int n = 0; for (auto& en : e.entries()) if (en.path == path) n++; return n;
}
static bool hasPath(NextZipEngine& e, const std::string& path) {
	for (auto& en : e.entries()) if (en.path == path) return true; return false;
}
static std::string readFile(const std::string& p) {
	FILE* f = fopen(p.c_str(), "rb"); if (!f) return "";
	char b[256] = {0}; size_t r = fread(b, 1, sizeof b - 1, f); fclose(f); return std::string(b, r);
}

int main(int argc, char** argv) {
	if (argc < 3) { printf("usage: %s 7z.so outDir\n", argv[0]); return 2; }
	std::string engine = argv[1], out = argv[2];
	std::string src = out + "/addsrc", coll = out + "/colsrc";
	::mkdir(src.c_str(), 0755); ::mkdir((src + "/sub").c_str(), 0755); ::mkdir(coll.c_str(), 0755);
	writeFile(src + "/a.txt", "original A");
	writeFile(src + "/sub/b.txt", "B contents");
	writeFile(out + "/extra.txt", "extra file");
	writeFile(coll + "/a.txt", "REPLACED A");   // same basename as the base entry → collision

	int failures = 0;
	for (std::string fmt : { std::string("zip"), std::string("7z"), std::string("tar") }) {
		printf("\n=== format %s ===\n", fmt.c_str());
		std::string arc = out + "/add." + fmt;
		{
			NextZipEngine e; e.setEnginePath(engine);
			NextZipEngine::CompressOptions o; o.format = fmt; o.level = 5;
			if (!e.compress(arc, o, { src + "/a.txt" })) { printf("FAIL base compress: %s\n", e.error().c_str()); failures++; continue; }
		}
		NextZipEngine e; e.setEnginePath(engine);
		if (!e.open(arc)) { printf("FAIL open: %s\n", e.error().c_str()); failures++; continue; }
		printf("base: entries=%zu hasA=%d\n", e.entries().size(), hasPath(e, "a.txt"));

		// 1) add a folder at root → folder + descendant present
		if (!e.addPaths({ src + "/sub" }, "")) { printf("FAIL add folder: %s\n", e.error().c_str()); failures++; }
		else if (!hasPath(e, "sub/b.txt")) { printf("FAIL: sub/b.txt missing after add folder\n"); failures++; }
		else printf("add folder OK: entries=%zu, sub/b.txt present\n", e.entries().size());

		// 2) add a file into a subfolder prefix → path is prefixed
		if (!e.addPaths({ out + "/extra.txt" }, "docs")) { printf("FAIL add prefixed: %s\n", e.error().c_str()); failures++; }
		else if (!hasPath(e, "docs/extra.txt")) { printf("FAIL: docs/extra.txt missing\n"); failures++; }
		else printf("add prefixed OK: docs/extra.txt present\n");

		// 3) collision → replace in place (no duplicate, count stable, content updated)
		size_t before = e.entries().size();
		if (!e.addPaths({ coll + "/a.txt" }, "")) { printf("FAIL add collision: %s\n", e.error().c_str()); failures++; }
		else {
			int dup = countPath(e, "a.txt"); size_t after = e.entries().size();
			if (dup != 1)            { printf("FAIL: a.txt appears %d times (want 1)\n", dup); failures++; }
			else if (after != before){ printf("FAIL: collision changed count %zu->%zu\n", before, after); failures++; }
			else                     printf("collision OK: a.txt single, count stable=%zu\n", after);
			std::string ex = out + "/ex_" + fmt; ::mkdir(ex.c_str(), 0755);
			if (e.extract({}, ex, "", false, 0, false)) {
				std::string got = readFile(ex + "/a.txt");
				if (got != "REPLACED A") { printf("FAIL: a.txt content not replaced (got '%s')\n", got.c_str()); failures++; }
				else printf("collision content OK: a.txt == 'REPLACED A'\n");
			} else { printf("FAIL: extract-verify: %s\n", e.error().c_str()); failures++; }
		}
	}

	// 4) negative: a single-stream gzip must refuse adds
	printf("\n=== negative: gzip single-stream ===\n");
	{
		std::string gz = out + "/one.gz";
		NextZipEngine e; e.setEnginePath(engine);
		NextZipEngine::CompressOptions o; o.format = "gzip"; o.level = 5;
		if (!e.compress(gz, o, { src + "/a.txt" })) { printf("FAIL gz compress: %s\n", e.error().c_str()); failures++; }
		else {
			NextZipEngine g; g.setEnginePath(engine);
			if (g.open(gz)) {
				if (g.addPaths({ out + "/extra.txt" }, "")) { printf("FAIL: addPaths to gz should have refused\n"); failures++; }
				else printf("gz correctly refused: %s\n", g.error().c_str());
			} else printf("note: gz reopen failed (%s) — skipping\n", g.error().c_str());
		}
	}

	printf("\n%s (failures=%d)\n", failures ? "TEST FAILED" : "ALL TESTS PASSED", failures);
	return failures ? 1 : 0;
}
