# NextZip — Architecture, Cocoa UI, and Plugin Integration

How to build the plugin on the 7-Zip engine, with a 7-Zip-File-Manager-style UI.

---

## 1. Engine integration (in-process)

**Build:** vendor the 7-Zip 26.01 source; compile the `Format7zF` object set (all
formats + codecs + COM glue) as a **universal static library** (arm64 with asm,
x86_64 with C fallback unless NASM is set up) — or as a relinkable `.dylib` the plugin
loads. CMake-ify the file list from `CPP/7zip/Bundles/Format7zF/makefile.gcc` (or call
the in-tree `cmpl_mac_arm64.mak` / `cmpl_mac_x64.mak` and `lipo`).

**Wrapper (ObjC++):** model on `CPP/7zip/UI/Client7z/Client7z.cpp` and the higher-level
`CPP/7zip/UI/Common/` (`OpenArchive`, `Extract`, `Update`, `LoadCodecs`). Provide a
small `NZArchive` class:

- `open(path)` → `CreateArchiver(&CLSID_Format, &IID_IInArchive, …)` (or auto-detect via
  `CArc`/`CArchiveLink` from `OpenArchive.cpp`) → `IInArchive::Open(fileStream, …)`.
- `count` / `property(index, kpid…)` → fill the table model (one row per entry; build a
  virtual folder tree from `kpidPath` for breadcrumb navigation).
- `extract(indices, destDir, callback)` → `IInArchive::Extract`; callback implements
  `IArchiveExtractCallback` + `ICryptoGetTextPassword` (NSAlert password sheet) +
  progress (`SetTotal`/`SetCompleted` → `NSProgressIndicator`).
- `create/update(destPath, items, options)` → `CreateArchiver(&CLSID, &IID_IOutArchive)`
  → `ISetProperties::SetProperties` (level/method/password/solid) →
  `IOutArchive::UpdateItems` with an `IArchiveUpdateCallback`.

**Streams:** reuse `CPP/7zip/Common/FileStreams.*`, or implement thin `ISequentialIn/
OutStream` wrappers over `fd`/`NSData` to stream an entry straight into a Nextpad++
editor tab (no temp file).

**Bridging:** `UString` (UTF-16) ↔ `NSString`/UTF-8 at the boundary
(`CPP/Common/StringConvert.*`). `PROPVARIANT` → typed Cocoa values for the columns.

**Crash safety:** honor every `HRESULT` (engine is internally `try`-guarded); never
deref on `S_FALSE`. For v1.1, optionally isolate the riskiest parsers (dmg/hfs/ext/
ntfs/vhd) by building a tiny **helper executable** from the same engine and driving it
over a pipe/XPC with a private protocol — process isolation without losing the rich
property access (strictly better than parsing a stock CLI's text output).

---

## 2. Cocoa UI — mimic the 7-Zip File Manager

7-Zip FM is a **flat single-folder list with navigation**, not a tree → use
**`NSTableView`**, not `NSOutlineView`.

**Container view (top → bottom):**
1. **`NSToolbar`** — image buttons Add, Extract, Test, Copy, Move, Delete, Info
   (SF Symbols e.g. `plus`, `square.and.arrow.up`, `checkmark.shield`, `doc.on.doc`,
   `arrow.right.doc.on.clipboard`, `trash`, `info.circle`); enable/disable per selection.
2. **Path / breadcrumb bar** — `NSPathControl` (or custom HStack) showing
   `archive.7z › subdir › subdir`, clickable; plus an "↑ up" button (the `..` behavior).
3. **`NSTableView`** — view-based, alternating rows, multi-select, **sortable columns**
   via `NSSortDescriptor`, each backed by a `kpid*`:
   - Name←`kpidName/Path`, Size←`kpidSize`, Packed Size←`kpidPackSize`,
     Modified←`kpidMTime`, Created←`kpidCTime`, Accessed←`kpidATime`,
     Attributes←`kpidAttrib`, Encrypted←`kpidEncrypted`, Comment←`kpidComment`,
     CRC←`kpidCRC` (hex), Method←`kpidMethod`, Characteristics←`kpidCharacts`,
     Host OS←`kpidHostOS`, Version/Volume/Offset←`kpidOffset` + arc props.
   - Folder rows (`kpidIsDir`) get a folder icon and sort first.
   - Default-show Name/Size/Packed/Modified/CRC/Method; rest toggleable via a
     right-click header menu (like FM).

**Navigation model (the FM trick):** keep a virtual cwd *inside* the archive; the table
shows children of cwd. Double-click a folder → push cwd; `..`/up → pop. Double-click a
**file** → open in the editor (text-ish) or extract+reveal. Double-click a **nested
archive** → descend into it by opening its `ISequentialInStream` with a new
`IInArchive` (keep a stack of open handles for the breadcrumb chain).

**Drag-out extract:** `NSFilePromiseProvider` (or `tableView:writeRowsWithIndexes:`) →
on drop to Finder, extract the selected entries to the drop dir.

**Context menu:** Extract, Extract Here, Test, Copy, Delete, Rename, Properties (Info) —
selection-scoped, same actions as the toolbar.

**Background work:** run extract/create on a `dispatch_queue`; marshal UI updates to
main (panel API is documented main-thread-marshaling-safe). Password + progress in
sheets.

---

## 3. Plugin integration (Nextpad++ macOS)

Standard 5-export `.dylib` (copy the structure from `AnalysePlugin/src/PluginEntry.mm`):
```objc
extern "C" NPP_EXPORT void        setInfo(NppData);
extern "C" NPP_EXPORT const char* getName(void);            // "NextZip"
extern "C" NPP_EXPORT FuncItem*   getFuncsArray(int* nbF);
extern "C" NPP_EXPORT void        beNotified(SCNotification*);
extern "C" NPP_EXPORT intptr_t    messageProc(uint32_t,uintptr_t,intptr_t);
```
Bundle a copy of `NppPluginInterfaceMac.h` in `NextZip/deps/`. Install to
`~/.nextpad++/plugins/NextZip/`. Build universal arm64+x86_64.

**Menu items:** "Show NextZip Archive Manager" (toggle/checkmark), "Open Archive…",
separator, "Add Current File to Archive…", "About NextZip".

**Window vs panel — do BOTH, default standalone window:**
- Primary: a free-floating **`NSWindowController`** (pattern: `NppFTP/src/ui/
  FTPWindowController.{h,mm}`) — most faithful to the 7-Zip FM; room for ~16 columns.
- Also register the same container `NSView` as a **dockable panel** via
  `NPPM_DMM_REGISTERPANEL` (+501) / `SHOWPANEL` (+502) / `HIDEPANEL` (+503) /
  `UNREGISTERPANEL` (+504) — see `AnalysePlugin/src/AnalyseController.mm`. (The panel
  API strong-retains the view.) Share one controller; a toolbar button "pop out to
  window."
  - ⚠️ Reuse the hard-won NppFTP lessons: NSOutlineView/NSTableView **retain item
    pointers across reloadData** (drop items before freeing the model); never do
    network/heavy work in per-cell accessors; register any UI provider the engine needs.

**Hooking file-open:**
- "Open Archive…" → `NSOpenPanel` filtered to archive UTIs.
- From the editor: `NPPM_GETFULLCURRENTPATH`; if it's an archive, offer "Open in NextZip".
- Auto-detect: in `beNotified`, watch `NPPN_FILEOPENED` / `NPPN_FILEBEFORELOAD`; if a
  file being loaded is a recognized archive (probe via `IInArchive::Open`), offer to
  open it in NextZip instead of dumping binary into the editor.
- Open a file *out of* an archive into the editor: extract its stream to a temp path →
  `NPPM_DOOPEN`/`NPPM_SWITCHTOFILE`. On save, write back via `IOutArchive::UpdateItems`
  (creatable formats only — **never RAR**).

---

## 4. Build/packaging notes
- Universal: arm64 (`USE_ASM=1`) + x86_64 (C fallback unless NASM), `lipo` together.
- Engine size: ~3–5 MB universal (all formats). Acceptable for a plugin.
- Ship LGPL + unRAR license texts; keep RAR source notices; no "Create RAR" in the UI.
- Catalog: add NextZip as a new plugin entry (repo under `nextpad-plus-plus`),
  notarize + staple like the other plugins.
