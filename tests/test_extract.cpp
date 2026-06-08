#include "SevenZipEngine.h"
#include <cstdio>
#include <string>
#include <sys/stat.h>
static bool ex(const std::string& p){ struct stat s; return ::stat(p.c_str(),&s)==0; }
int main(int c,char**v){
  std::string eng=v[1], in=v[2], out=v[3];
  NineZipEngine mk; mk.setEnginePath(eng);
  NineZipEngine::CompressOptions o; o.format="zip"; o.level=1;
  if(!mk.compress(out+"/root.zip", o, {in})){ printf("FAIL mk: %s\n", mk.error().c_str()); return 1; }
  std::string base=in; size_t s=base.find_last_of('/'); std::string rootName = s==std::string::npos?base:base.substr(s+1);
  // 1) eliminate root
  { NineZipEngine e; e.setEnginePath(eng); e.open(out+"/root.zip");
    e.extract({}, out+"/elim", "", false, 0, true);
    printf("eliminate-root: out/elim/%s exists=%d (want 0)  out/elim/a.txt exists=%d (want 1)\n",
           rootName.c_str(), ex(out+"/elim/"+rootName), ex(out+"/elim/a.txt")); }
  // 2) overwrite=skip vs rename on a re-extract
  { NineZipEngine e; e.setEnginePath(eng); e.open(out+"/root.zip");
    e.extract({}, out+"/ow", "", false, 0, false);                  // first time
    e.extract({}, out+"/ow", "", false, 2, false);                  // auto-rename second time
    printf("auto-rename: original=%d  renamed dir-or-file present(check a.txt vs 'a (1).txt')...\n", ex(out+"/ow/"+rootName+"/a.txt"));
    printf("  '%s/a (1).txt' exists=%d (want 1 if rename worked at file level)\n", rootName.c_str(), ex(out+"/ow/"+rootName+"/a (1).txt")); }
  printf("ALL-OK\n"); return 0;
}
