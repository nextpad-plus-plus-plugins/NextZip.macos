# NineZip

A 7-Zip-style archive manager plugin for **Nextpad++** (macOS). Built on the
official 7-Zip engine (linked in-process via the COM `IInArchive`/`IOutArchive`
API), so it handles every format 7-Zip supports.

## Status

- ✅ 7-Zip engine (v26.01) fetched from 7-zip.org at build time (not vendored),
  sha256-verified, and built as a universal arm64+x86_64 shared lib
  (`deps/7z.so`) via `deps/build-7z-engine.sh`.
- ✅ In-process engine wrapper (`src/SevenZipEngine.{h,cpp}`) — `dlopen`s the
  engine, auto-detects format, opens + lists entries (name/size/packed/CRC/
  method/mtime/encrypted). Validated on 7z, zip, tar, gzip, and **rar**.
- ✅ Dockable two-pane File-Manager (`NineZipController`): a filesystem browser
  on top (single-click an archive to view it) and the archive contents below
  (breadcrumb, drill into folders, Extract/Test/Info).
- ✅ Open a file from an archive in the editor (extract-on-the-fly to temp);
  saving it writes the edit back into the archive (writable formats only).
- ✅ Transparent nested-archive descent: `.tar.gz` / `.tar.bz2` / `.tar.xz`
  open straight to the inner tar's files, and save-back re-wraps outward.

### Next
Add/Delete entries, drag-out-to-extract, create-new-archive,
password + progress sheets.

## Formats
- **Extract / browse:** detection is by content signature (not extension), over
  ~30 formats — 7z, zip, **rar / rar5**, tar, gz, bz2, xz, z, cab, xar, rpm,
  deb, arj, lzh, chm, nsis, msi/compound, cpio, plus disk images iso, udf, dmg,
  hfs, apfs, squashfs, cramfs, ext, wim, vhd, vhdx, vdi, vmdk, qcow.
- **Create / save-back:** 7z, zip, tar, gz, bz2, xz, wim (the 7-Zip writable set).
- **RAR is extraction-only** — the RAR compression algorithm is proprietary and
  cannot be created by anything but WinRAR (unRAR license). NineZip never offers
  "create RAR".

## Build
```sh
deps/build-7z-engine.sh          # fetches + verifies + builds the universal 7z.so engine
cmake -S . -B build && cmake --build build
cmake --install build            # → ~/.nextpad++/plugins/NineZip/{NineZip.dylib, 7z.so}
```
The first build downloads the 7-Zip source (~1.5 MB) from 7-zip.org and
sha256-verifies it; subsequent builds reuse `deps/7zip/`.

## Licensing
- NineZip: GPL (same family as Nextpad++).
- Engine: 7-Zip — LGPL-2.1, with the **unRAR restriction** on the RAR codec
  (`License.txt`, `unRarLicense.txt` from the 7-Zip source, shipped alongside
  the plugin). The RAR sources may not be used to build a RAR-compatible
  *archiver*.
