# NextZip — Engine Decision & Recommendation

**Date:** 2026-06-07
**Question:** Build the Nextpad++ archive plugin ("NextZip") on the **7-Zip source**
(`/Users/leto/development/github/7zip`) or on **Keka**
(`/Users/leto/development/github/Keka`)? Goal: a 7-Zip-File-Manager-style archive
manager supporting **all 7-Zip formats including RAR**.

---

## TL;DR — Use the 7-Zip source. Do NOT base it on Keka.

| | **7-Zip source** | **Keka** |
|---|---|---|
| Is there reusable *engine* code in the repo? | **Yes** — the whole engine (C/CPP/Asm) | **No** — repo is only translations + wiki + 3rd-party source tarballs; Keka.app itself is closed-source |
| Create archives (compress)? | **Yes** (7z, zip, tar, gz, bz2, xz, wim) | n/a (no Keka engine); its bundled tools do, by shelling out |
| Extract all formats incl. RAR? | **Yes** (RAR4 + RAR5 read-only) | Via bundled `unar`/XADMaster (extract-only) |
| Native macOS build? | **Yes** — official clang arm64 + x86_64 makefiles, POSIX layer mainlined | Keka = a built `.app`; not a library |
| Fits "one self-contained plugin .dylib"? | **Yes** — link as static lib / load a `.dylib` | **Poor** — Keka's model is an app that fork/execs bundled CLI tools |
| Same engine as Windows 7-Zip File Manager? | **Yes** (identical engine + the exact column model) | No |
| License | LGPL-2.1 (+ unRAR restriction on RAR files) | App proprietary; bundled tools LGPL/GPL |

**Decision: vendor and build the 7-Zip 26.01 source as a universal static library and
call its `IInArchive`/`IOutArchive` API in-process** (modeled on the in-tree
`Client7z.cpp` sample). This is the same engine the Windows 7-Zip File Manager uses,
so the column grid, format coverage, and behavior match 1:1.

**Keka contributes essentially nothing reusable.** The public Keka repo has *no app
source code* — it's the issues/wiki/translations repo plus source tarballs of
third-party CLI tools (`unar`, `lzip`, `plzip`, `lbzip2`). Its only genuinely useful
asset is `Bin/unar.tgz` → **XADMaster** (LGPL, extract-only), and even that is
inferior to 7-Zip for our needs because (a) it can't *create* archives and (b) 7-Zip
already covers RAR extraction. The ~30 MB you saw is the *built app* bundling
compiled CLI tools + Cocoa UI + 32 localizations — not something we'd embed.

---

## Why 7-Zip in-process (not a bundled CLI)

- **Rich columns for free.** The 7-Zip File Manager columns (Name, Size, Packed Size,
  Modified/Created/Accessed, Attributes, Encrypted, Comment, CRC, Method,
  Characteristics, Host OS, Version, Volume, Offset) map **1:1** to
  `IInArchive::GetProperty(index, kpid…)`. Shelling out to a CLI only gives you
  `7z l -slt` text to re-parse — fragile and column-incomplete.
- **Streaming.** Extract an entry straight into memory via `ISequentialOutStream` →
  open it in a Nextpad++ editor tab without temp-file round-trips.
- **Universal binary is trivial** (`-arch arm64 -arch x86_64`, same as every other
  plugin here). Official `cmpl_mac_arm64.mak` / `cmpl_mac_x64.mak` prove both slices build.
- **No bundled executables to notarize/sign separately** (a `.dylib` can't contain
  executables anyway).

The one real risk — a malformed archive (esp. the heuristic disk-image/filesystem
parsers: NTFS/HFS/ext/dmg/vhd) crashing and taking down the **host** — is mitigated
two ways: (1) honor 7-Zip's `HRESULT` everywhere (it's internally `try`-guarded) for
v1; (2) optionally move risky parsing into a small **XPC/helper process** built from
the same engine in v1.1 for true isolation. See `30_architecture-and-ui.md`.

---

## RAR — the hard constraint (read the details in `20_format-matrix-and-rar.md`)

- **RAR can be EXTRACTED** (list/test/decompress, RAR4 **and** RAR5) via 7-Zip's
  `Rar`/`Rar5` handlers + decoders.
- **RAR can NEVER be CREATED** — not by 7-Zip, p7zip, libarchive, unar, or anyone but
  RARLAB's licensed `rar`/WinRAR. The 7-Zip tree has **no RAR encoder** (the codec
  registers a `NULL` encoder pointer by design).
- The **unRAR license** requires: ship the LGPL + unRAR license texts, keep the
  "may not be used to develop a RAR-compatible archiver" notice in source/docs, and
  **never expose a "Create RAR" option** in the UI.

---

## Recommended v1 scope

- **Engine:** 7-Zip 26.01 `Format7zF` (all formats + codecs) built universal static lib.
- **Create formats:** 7z, zip, tar, gz, bz2, xz, wim (+ tar.gz/tar.bz2/tar.xz).
- **Extract formats:** everything 7-Zip supports (~50), including RAR4/RAR5 (read-only).
- **UI:** standalone `NSWindowController` (primary, most 7-Zip-FM-like) + optional
  dockable panel; `NSToolbar` (Add/Extract/Test/Copy/Move/Delete/Info), breadcrumb
  path bar, flat sortable `NSTableView` with the FM columns, descend into folders and
  **nested archives**, drag-out-to-extract, password + progress sheets.
- **Plugin:** standard 5-export `.dylib`; menu items + `NPPM_GETFULLCURRENTPATH` /
  `NPPN_FILEOPENED` hooks to open archives; `NPPM_DOOPEN` to push extracted files into
  the editor.

## Effort estimate
- Engine build (universal `.dylib` + Client7z smoke test): ~1–2 days (makefiles exist).
- The real work: the Cocoa File-Manager UI + `UString`↔`NSString` bridging + the
  open/extract/update callback objects + plugin wiring — comparable to the NppFTP UI
  phase.

## Companion documents
- `10_7zip-vs-keka.md` — detailed repo analyses (what each repo actually contains).
- `20_format-matrix-and-rar.md` — full format create/extract matrix + RAR licensing.
- `30_architecture-and-ui.md` — engine integration, Cocoa UI design, plugin wiring.
