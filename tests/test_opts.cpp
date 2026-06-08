// Validate the full CompressOptions → 7-Zip property mapping.
#include "SevenZipEngine.h"
#include <cstdio>
#include <string>

static std::string lastMethod(NineZipEngine& r) {
	for (auto it = r.entries().rbegin(); it != r.entries().rend(); ++it)
		if (!it->isDir) return it->method;
	return "";
}

int main(int argc, char** argv) {
	if (argc < 4) { printf("usage: %s 7z.so inDir outDir\n", argv[0]); return 2; }
	std::string eng = argv[1], in = argv[2], out = argv[3];

	// 1) 7z + LZMA2 + dict/word/solid/threads at level 9
	{
		NineZipEngine e; e.setEnginePath(eng);
		NineZipEngine::CompressOptions o;
		o.format = "7z"; o.level = 9; o.method = "LZMA2";
		o.dict = 32ull << 20; o.wordSize = 64; o.solid = "on"; o.threads = 2;
		if (!e.compress(out + "/a.7z", o, {in})) { printf("FAIL 7z: %s\n", e.error().c_str()); return 1; }
		NineZipEngine r; r.setEnginePath(eng);
		if (!r.open(out + "/a.7z")) { printf("FAIL reopen 7z: %s\n", r.error().c_str()); return 1; }
		printf("7z   entries=%zu method=%s\n", r.entries().size(), lastMethod(r).c_str());
	}
	// 2) 7z + PPMd
	{
		NineZipEngine e; e.setEnginePath(eng);
		NineZipEngine::CompressOptions o;
		o.format = "7z"; o.level = 5; o.method = "PPMd"; o.dict = 16ull << 20; o.wordSize = 6;
		if (!e.compress(out + "/p.7z", o, {in})) { printf("FAIL ppmd: %s\n", e.error().c_str()); return 1; }
		NineZipEngine r; r.setEnginePath(eng); r.open(out + "/p.7z");
		printf("ppmd method=%s\n", lastMethod(r).c_str());
	}
	// 3) zip + AES-256 encryption + Deflate
	{
		NineZipEngine e; e.setEnginePath(eng);
		NineZipEngine::CompressOptions o;
		o.format = "zip"; o.level = 5; o.method = "Deflate"; o.password = "secret"; o.encMethod = "AES256";
		if (!e.compress(out + "/enc.zip", o, {in})) { printf("FAIL zip enc: %s\n", e.error().c_str()); return 1; }
		NineZipEngine r; r.setEnginePath(eng); r.open(out + "/enc.zip");
		bool anyEnc = false; for (auto& en : r.entries()) if (en.encrypted) anyEnc = true;
		printf("zip  encrypted=%d method=%s\n", anyEnc, lastMethod(r).c_str());
		NineZipEngine x; x.setEnginePath(eng); x.open(out + "/enc.zip");
		bool ok  = x.extract({}, out + "/ex_ok",  "secret");
		NineZipEngine y; y.setEnginePath(eng); y.open(out + "/enc.zip");
		bool bad = y.extract({}, out + "/ex_bad", "wrong");
		printf("extract: correct-pw=%d wrong-pw=%d (wrong must be 0)\n", ok, bad);
		if (!ok || bad) { printf("FAIL encryption round-trip\n"); return 1; }
	}
	// 4) path mode: full
	{
		NineZipEngine e; e.setEnginePath(eng);
		NineZipEngine::CompressOptions o; o.format = "zip"; o.level = 1; o.pathMode = 1;
		if (!e.compress(out + "/full.zip", o, {in})) { printf("FAIL full: %s\n", e.error().c_str()); return 1; }
		NineZipEngine r; r.setEnginePath(eng); r.open(out + "/full.zip");
		printf("full-path first entry=%s\n", r.entries().empty() ? "" : r.entries().front().path.c_str());
	}
	printf("ALL-OK\n");
	return 0;
}
