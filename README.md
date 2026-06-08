# NineZip

A 7-Zip-style archive manager plugin for **Nextpad++** (macOS). Built on the
official 7-Zip engine (linked in-process via the COM `IInArchive`/`IOutArchive`
API), so it handles every format 7-Zip supports.

## Status: scaffold

- ✅ 7-Zip engine vendored (`deps/7zip/`, v26.01) and built as a universal
  arm64+x86_64 shared lib (`deps/7z.so`) via `deps/build-7z-engine.sh`.
- ✅ In-process engine wrapper (`src/SevenZipEngine.{h,cpp}`) — `dlopen`s the
  engine, auto-detects format, opens + lists entries (name/size/packed/CRC/
  method/mtime/encrypted). Validated on 7z, zip, tar, gzip, and **rar**
  (a real 1369-entry .rar lists correctly).
- ✅ Plugin skeleton: 5 exports + menu (Open Archive… / Open Current File as
  Archive / About) and a window (`NineZipController`) that lists an opened
  archive in a sortable table — the seed of the File-Manager UI.

### Next
Toolbar (Add/Extract/Test/Delete/Info), breadcrumb path bar, descend into
folders **and nested archives**, extract (incl. to-temp → open in the editor),
create/update for the writable formats, drag-out-to-extract, password + progress
sheets, optional dockable panel.

## Formats
- **Extract:** all 7-Zip formats — 7z, zip, tar, gz, bz2, xz, **rar / rar5**,
  iso, cab, dmg, wim, arj, lzh, rpm, cpio, hfs/ext/ntfs images, etc.
- **Create:** 7z, zip, tar, gz, bz2, xz, wim (the 7-Zip writable set).
- **RAR is extraction-only** — the RAR compression algorithm is proprietary and
  cannot be created by anything but WinRAR (unRAR license). NineZip never offers
  "create RAR". See `docs/20_format-matrix-and-rar.md`.

## Build
```sh
deps/build-7z-engine.sh          # builds the universal 7z.so engine
cmake -S . -B build && cmake --build build
cmake --install build            # → ~/.nextpad++/plugins/NineZip/{NineZip.dylib, 7z.so}
```

## Licensing
- NineZip: GPL (same family as Nextpad++).
- Engine: 7-Zip — LGPL-2.1, with the **unRAR restriction** on the RAR codec
  (`deps/7zip/docs/License.txt`, `unRarLicense.txt`, shipped with the plugin).
  The RAR sources may not be used to build a RAR-compatible *archiver*.

See `docs/` for the full engine investigation and architecture plan.
