# 7-Zip source vs Keka — Detailed Repository Analysis

Investigation of the two candidate repos for the NextZip engine.

---

## A. `/Users/leto/development/github/7zip` — official 7-Zip source (USE THIS)

Igor Pavlov's official source, **version 26.01** (`C/7zVersion.h`, 2026-04-27).
Layout: `C/` (core codecs), `CPP/` (the COM-style archive engine + clients),
`Asm/` (optimized asm), `docs/` (licenses). 16 MB.

### License (`docs/License.txt`, `docs/copying.txt`, `docs/unRarLicense.txt`)
- **Bulk: GNU LGPL 2.1-or-later.** "If there is no license information in some source
  file, that file is under the GNU LGPL."
- **`CPP/7zip/Compress/Rar*`: LGPL + the unRAR license restriction** (both apply).
- **BSD-3:** `CPP/7zip/Compress/LzfseDecoder.cpp`, `C/ZstdDec.c`. **BSD-2:** `C/Xxh64.c`.
- Compliance: keep the engine as a **relinkable library** the plugin loads/links;
  ship the license texts; honor the RAR notice (see `20_…`). LGPL is compatible with
  the GPL Nextpad++/plugin family.

### The COM-style SDK API (the core of the integration)
Windows-COM-style, implemented portably (ref-counted `IUnknown`, `HRESULT`,
`PROPVARIANT`). Key headers:

- **Streams** — `CPP/7zip/IStream.h`: `ISequentialInStream::Read`,
  `ISequentialOutStream::Write`, `IInStream::Seek`, `IOutStream::Seek/SetSize`.
  Ready-made impls in `CPP/7zip/Common/FileStreams.{h,cpp}` — wrap fd/NSData/NSFileHandle.
- **Read** — `CPP/7zip/Archive/IArchive.h`, `IInArchive`:
  `Open(stream, maxStart, openCallback)`, `GetNumberOfItems`,
  `GetProperty(index, propID, value)`, `Extract(indices, num, testMode, callback)`,
  `GetArchiveProperty`, plus `GetPropertyInfo` (column discovery).
- **Write** — `IOutArchive::UpdateItems(outStream, numItems, updateCallback)`;
  options via `ISetProperties::SetProperties` (level/method/password/solid…).
- **Callbacks** — `IArchiveOpenCallback` (SetTotal/SetCompleted),
  `IArchiveExtractCallback` (GetStream/PrepareOperation/SetOperationResult),
  `IArchiveUpdateCallback` (GetUpdateItemInfo/GetProperty/GetStream),
  `ICryptoGetTextPassword` for passwords (`CPP/7zip/IPassword.h`).
- **Column PROPIDs** — `CPP/7zip/PropID.h`: `kpidPath/kpidName`, `kpidSize`,
  `kpidPackSize`, `kpidAttrib`, `kpidMTime/kpidCTime/kpidATime`, `kpidCRC`,
  `kpidMethod`, `kpidEncrypted`, `kpidComment`, `kpidHostOS`, `kpidOffset`,
  `kpidCharacts`, `kpidIsDir` — exactly the 7-Zip FM columns.
- **Factory exports** (the `.dylib`/static entry points): `CreateObject` /
  `CreateArchiver(clsID, iid, **out)` (`CPP/7zip/Archive/ArchiveExports.cpp`),
  `GetNumberOfFormats`, `GetHandlerProperty2(index, propID, value)` (enumerate
  formats + name/ext/signature/ClassID/Update flag). Each format = a 16-byte GUID
  `{23170F69-40C1-278A-1000-000110xx0000}` (xx = format id; 7z=0x07, Zip=0x01,
  BZip2=0x02, Xz=0x0C, Tar=0xEE, GZip=0xEF).

### Reference clients in the tree (blueprints to copy)
- **`CPP/7zip/UI/Client7z/Client7z.cpp`** (~1145 lines) — THE SDK reference. Implements
  add/list/extract: `dlopen`s `7z.so` (`#define kDllName "7z.so"` on non-Windows),
  resolves `CreateObject`, opens, lists via `GetProperty(kpidPath/kpidSize)`, extracts
  with a `CArchiveExtractCallback : IArchiveExtractCallback, ICryptoGetTextPassword`,
  creates via `UpdateItems`. Copy this skeleton for the engine wrapper.
- **`CPP/7zip/UI/Common/`** — the higher-level layer the real FM uses:
  `OpenArchive.{h,cpp}` (CArc/CArchiveLink: auto-detect format, multi-volume, **nested
  archives**), `Extract.cpp`, `Update.cpp`, `LoadCodecs.{h,cpp}` (CCodecs registry),
  `ArchiveExtractCallback.cpp`, `UpdateCallback.cpp`. Building on this gets format
  auto-detection + FM-grade behavior for free.
- `CPP/7zip/Bundles/Format7zF/` builds the all-format `7z.so`/`.dylib`.
- `CPP/7zip/UI/FileManager/` = the Windows FM (Win32/MFC — **not** reusable on macOS,
  but a behavioral spec for our Cocoa UI).

### Formats & codecs
45 single-file + ~12 container handlers in `CPP/7zip/Archive/` (full list in
`20_format-matrix-and-rar.md`). Codecs in `CPP/7zip/Compress/`: LZMA/LZMA2 (enc+dec),
PPMd (enc+dec), Deflate/Deflate64 (enc+dec), BZip2 (enc+dec), Xz (enc+dec); legacy
decoders (Z/Shrink/Implode/Quantum/Lzx/Lzms/Xpress/Lzfse/Lzh); **Zstd decoder only**
(no encoder); filters BCJ/BCJ2/Delta/ByteSwap; AES in `CPP/7zip/Crypto/` + `C/Aes*.c`.
RAR: decoders `Rar1/2/3/5Decoder.cpp` present; **no RAR encoder**.

### Build on macOS — first-class, no p7zip needed
- **Official clang mak files present**: `CPP/7zip/cmpl_mac_arm64.mak`,
  `cmpl_mac_x64.mak`, `var_mac_arm64.mak`, `var_mac_x64.mak`, `warn_clang_mac.mak`
  (`CC=clang CXX=clang++`, `-arch arm64`, `USE_ASM=1`/`USE_CLANG=1`). Build each arch
  then `lipo` (no single fat target).
- **POSIX layer mainlined** in `CPP/Common/MyWindows.h` (under `#else // _WIN32`):
  typedefs BYTE/WORD/BOOL/BSTR/FILETIME, `HRESULT`/`S_OK`, full `PROPVARIANT`/`VARIANT`,
  `VariantClear/SysAllocString/CompareFileTime` (impl in `MyWindows.cpp`). No registry,
  no Win32 GUI dependency in the engine.
- **`UString`** (UTF-16) ↔ `NSString`/UTF-8 bridging at the plugin boundary is the main
  glue to write (`CPP/Common/MyString.*`, `StringConvert.*`).

### Asm + C fallback
- `Asm/arm64/` = `7zAsm.S` + `LzmaDecOpt.S` in clang `.S` syntax → native on Apple
  Silicon (wired by the mac makefile). AES/SHA on arm64 use ARMv8 **intrinsics** in
  `C/AesOpt.c`/`Sha256Opt.c`.
- `Asm/x86/` = MASM/NASM `.asm` → needs NASM on x86_64, OR set `USE_ASM=` (empty) to
  link the **pure-C** fallbacks in `C/` (every asm routine has a C twin). Recommended:
  arm64 with asm, x86_64 C-fallback unless NASM is set up.

### What to link & size
**Recommended:** build the **`Format7zF`** object set → one universal `.dylib`/static
lib with **all** formats + codecs + COM glue (~3–5 MB universal; covers list/extract/
create + RAR-extract). Trimming to a minimal static lib (7z+zip+tar+gz+bz2+xz+RAR)
saves little (~1.5–3 MB) and loses coverage a File-Manager UI implies. Go full.

---

## B. `/Users/leto/development/github/Keka` — NOT a usable engine

The public `aonez/Keka` repo. 78 MB checkout. **Contains NO Keka application source.**

### What's actually here
- `find` for `*.swift / *.m / *.mm / *.xcodeproj` → **nothing**. No `.gitmodules`.
- README states: *"This repository is used mainly to take care of Issues and have a
  collaborative Wiki."* **Keka.app is closed-source**, shipped only as built binaries
  from keka.io.
- Top level: `Bin/` (3rd-party tool **source tarballs**), `Translations-{macOS,iOS,Web}/`
  (32 `.lproj`), `Wiki/` (screenshots), `Img/`, `README.md`.

### `Bin/` = source tarballs of third-party CLI tools (not binaries)
| Tarball | Extracted | What | License |
|---|---|---|---|
| `unar.tgz` | 9.3 MB | **unar/XADMaster** (+ UniversalDetector) | **LGPL 2.1** |
| `lbzip2.tgz` | 3.4 MB | parallel bzip2 | GPL v3 |
| `plzip.tgz` | 0.7 MB | parallel lzip | GPL |
| `lzip.tgz` | 0.4 MB | lzip (LZMA) | GPL v2 |

- **XADMaster** (in `unar.tgz`) is the one notable asset: a universal **extraction**
  engine with dedicated RAR (`XADRARParser.m`, `XADRAR5Parser.m`) + 7z
  (`XAD7ZipParser.m`) + ~50 format parsers + `unar`/`lsar` CLIs. **Extract-only** (no
  compression/create path).
- **No p7zip, no 7z, no unrar binary in this repo.** The Wiki images
  (`Wiki/Images/rar-binary-*.png`) show Keka asks the *user* to supply their own
  `rar`/`unrar` at runtime — it doesn't ship the non-free RAR tools.

### Keka's actual architecture
A **Cocoa app that fork/execs bundled CLI tools and parses their output** — 7z for
zip/7z/tar create+extract, lzip/plzip/lbzip2 for those formats, `unar`/`lsar` for the
universal extract path, user-supplied `rar`/`unrar` for RAR. It does **not** embed
archiving as in-process libraries.

### Why this is a poor fit for NextZip
- A Nextpad++ plugin is **one `.dylib` in the host process**; Keka's whole model is a
  separate `.app` spawning helper processes. To replicate it you'd ship a `bin/` dir of
  notarized CLI tools next to the dylib and `NSTask` them — brittle stdout parsing,
  incomplete columns, temp-file round-trips, extra signing burden. Net: worse than
  linking 7-Zip in-process, and you'd *still* pull in 7-Zip anyway for create.
- The ~30 MB installed size = the built app bundling those compiled universal tools +
  Cocoa UI + 32 localizations. Dominated by the unar/XADMaster engine + 7z CLI.

### The only thing worth borrowing
- **XADMaster** *could* be embedded as an LGPL static lib for a clean in-process RAR/7z
  **extract** path — but 7-Zip already does RAR/7z extract and also *creates*, so there's
  no reason to add XADMaster. Skip it for v1.
- **Translations** (`Translations-macOS/` — 32 languages of archiving-domain `.strings`)
  are a useful **glossary reference** for translating NextZip's own strings, but they're
  keyed to Keka's UI and have no clear OSS license — use as reference, don't copy verbatim.

### Conclusion
There is **no "Keka engine" to base NextZip on.** The repo is translations + wiki +
third-party tool sources. 7-Zip is strictly the better foundation.
