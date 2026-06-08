# Format Matrix & RAR Licensing

Source: 7-Zip 26.01 (`/Users/leto/development/github/7zip`), derived by cross-referencing
every `CPP/7zip/Archive/*Handler.cpp` against which expose `IOutArchive`/implement
`UpdateItems` (the create path).

---

## 1. RAR — the critical legal constraint

### The unRAR license (verbatim, `docs/unRarLicense.txt`, clause 2)
> "The unRAR sources may be used in any software to handle RAR archives without
> limitations free of charge, but **cannot be used to re-create the RAR compression
> algorithm, which is proprietary.** Distribution of modified unRAR sources … is
> permitted, **provided that it is clearly stated in the documentation and source
> comments that the code may not be used to develop a RAR (WinRAR) compatible
> archiver.**"

7-Zip's own `docs/License.txt` marks `CPP/7zip/Compress/Rar*` as **"LGPL + unRAR
license restriction"** (both rule-sets apply). The codec self-documents it —
`Compress/Rar5Decoder.cpp:2`:
> `// According to unRAR license, this code may not be used to develop a program that creates RAR archives`

### What it means for NextZip
- **RAR EXTRACT (list / test / decompress): YES.** Handlers
  `Archive/Rar/RarHandler.cpp` (RAR1–4 = "RAR4") and `Archive/Rar/Rar5Handler.cpp`
  (RAR5), with decoders `Compress/Rar1/2/3/5Decoder.cpp`. Both register read-only
  (`REGISTER_ARC_I`) with signature search; NextZip reads RAR4 **and** RAR5
  transparently (handler chosen by signature).
- **RAR CREATE: NEVER.** Not by 7-Zip, p7zip, libarchive, unar, or anything except
  RARLAB's licensed `rar`/WinRAR. Proof in the tree: `Compress/RarCodecsRegister.cpp`
  registers each RAR codec as `{ CreateCodec, NULL, … }` — the **encoder pointer is
  hard-NULL**; there is no `Rar*Encoder.cpp` anywhere.

### Compliance checklist (NextZip inherits LGPL-2.1 + unRAR restriction)
1. Ship `License.txt` (LGPL 2.1), `copying.txt`, and `unRarLicense.txt` with the plugin.
2. Keep the "may not be used to develop a RAR-compatible archiver" notice in the
   vendored source comments; repeat it in NextZip's README/About.
3. The UI **must never offer "Create RAR" / "Add to .rar"** — filter RAR out of the
   create-format dropdown. RAR is extract/test/list only.
4. LGPL relink rights: satisfied because the engine is open and the plugin itself is
   open-source (lives in `nppPluginsMacOS`).
5. No per-copy/commercial fee applies (clause 2 is "free of charge … without
   limitations" for the *handling* use case).

---

## 2. Full format matrix

**Create-capable** (implement `UpdateItems`/`IOutArchive`):
`7z, zip, tar, gz, bz2, xz, wim, swf` — and `zstd`* (see caveat). Everything else is
**extract/list/test only**.

| Format | Handler | Extract | Create | Notes |
|---|---|:---:|:---:|---|
| **7z** | `7z/7zHandler*` | ✅ | ✅ | Native; LZMA/LZMA2/PPMd/BCJ2; AES-256 |
| **zip** | `Zip/ZipHandlerOut.cpp` | ✅ | ✅ | Deflate/Deflate64/BZip2/LZMA/PPMd/Store; AES + ZipCrypto |
| **tar** | `Tar/TarHandlerOut.cpp` | ✅ | ✅ | combine w/ gz/bz2/xz for `.tar.*` |
| **gzip (gz)** | `GzHandler.cpp` | ✅ | ✅ | single stream |
| **bzip2 (bz2)** | `Bz2Handler.cpp` | ✅ | ✅ | |
| **xz** | `XzHandler.cpp` | ✅ | ✅ | LZMA2 container |
| **wim** | `Wim/WimHandlerOut.cpp` | ✅ | ✅ | Windows imaging |
| **swf** | `SwfHandler.cpp` | ✅ | ✅ | Flash (niche) |
| **zstd** | `ZstdHandler.cpp` | ✅ | ⚠️ | handler has out-path, but tree ships **decoder only** — no encoder; treat as extract-only unless you vendor libzstd |
| **rar / rar5** | `Rar/RarHandler.cpp`, `Rar5Handler.cpp` | ✅ | ❌ | **read-only, unRAR-restricted** |
| **lzh/lha** | `LzhHandler.cpp` | ✅ | ❌ | |
| **arj** | `ArjHandler.cpp` | ✅ | ❌ | |
| **cab** | `Cab/` | ✅ | ❌ | MSZIP/LZX/Quantum |
| **iso / udf** | `Iso/`, `Udf/` | ✅ | ❌ | |
| **cpio** | `CpioHandler.cpp` | ✅ | ❌ | |
| **z (.Z)** | `ZHandler.cpp` | ✅ | ❌ | |
| **ar / deb** | `ArHandler.cpp` | ✅ | ❌ | deb = ar container |
| **rpm** | `RpmHandler.cpp` | ✅ | ❌ | unwraps to cpio |
| **dmg** | `DmgHandler.cpp` | ✅ | ❌ | Apple disk image |
| **hfs / hfs+** | `HfsHandler.cpp` | ✅ | ❌ | |
| **apfs** | `ApfsHandler.cpp` | ✅ | ❌ | |
| **ext 2/3/4** | `ExtHandler.cpp` | ✅ | ❌ | |
| **ntfs / fat** | `NtfsHandler.cpp`, `FatHandler.cpp` | ✅ | ❌ | |
| **vhd/vhdx/vmdk/vdi/qcow** | resp. handlers | ✅ | ❌ | VM disk images |
| **msi/com/chm** | `ComHandler.cpp`, `Chm/` | ✅ | ❌ | OLE / CHM help |
| **squashfs/cramfs** | resp. handlers | ✅ | ❌ | |
| **nsis** | `Nsis/` | ✅ | ❌ | installer introspection |
| **xar / pkg** | `XarHandler.cpp` | ✅ | ❌ | macOS .pkg |
| **elf/pe/macho/mub** | resp. handlers | ✅ | ❌ | executable section listing |
| **mbr/gpt/apm/lvm/avb/sparse/split** | various | ✅ | ❌ | partition/volume layout |

⚠️ **Decoder-only codecs** (so those formats are extract-only even where a handler
exists): zstd, lzfse, lzms, lzx, quantum, implode, shrink, xpress.

### Net v1 create set
**7z, zip, tar, gz, bz2, xz, wim** (+ tar.gz/tar.bz2/tar.xz). This matches what the
Windows 7-Zip File Manager offers in its "Add" dropdown. **Extract = the whole table.**
