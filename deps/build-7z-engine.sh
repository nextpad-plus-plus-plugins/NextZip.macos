#!/bin/bash
# Build the 7-Zip engine (Format7zF: all formats + codecs) as a universal
# arm64+x86_64 shared library -> deps/7z.so. The NextZip plugin dlopen()s this
# at runtime and calls CreateObject / IInArchive / IOutArchive.
#
# The 7-Zip source (deps/7zip/) is NOT vendored in git — it is fetched on first
# build from 7-zip.org and sha256-verified, then local patches from
# deps/patches/*.patch are applied (idempotently, so re-runs are safe). The
# macOS makefiles (cmpl_mac_*.mak, var_mac_*.mak, warn_clang_mac.mak) are part
# of upstream 7-Zip. arm64 uses the in-tree native assembly; x86_64 falls back
# to pure C unless NASM is installed (the .asm files are MASM/NASM dialect).
set -e
export PATH="/opt/homebrew/bin:$PATH"
# Pin the min deployment target: without this clang defaults to the build
# machine's SDK version (e.g. 26.x), stamping a minos that refuses to load on
# every older macOS — the exact bug of NextZip issue #1. Keep in sync with
# CMAKE_OSX_DEPLOYMENT_TARGET in CMakeLists.txt.
export MACOSX_DEPLOYMENT_TARGET="11.0"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/7zip"
BUNDLE="$SRC/CPP/7zip/Bundles/Format7zF"
JOBS="$(sysctl -n hw.ncpu)"

# ── bootstrap: fetch + verify + extract upstream 7-Zip if not present ──────────
SZ_VER="2601"                       # 7-Zip 26.01 (2026-04-27)
SZ_TARBALL="7z${SZ_VER}-src.tar.xz"
SZ_URL="https://www.7-zip.org/a/${SZ_TARBALL}"
SZ_SHA256="b2389e0e930b2f9a348cf0fe7d9870a46482a8ec044ee0bdf42e2136db31c3d6"
if [ ! -f "$BUNDLE/makefile" ]; then
	echo "[7z] source not present — fetching 7-Zip ${SZ_VER} from 7-zip.org…"
	TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
	curl -fL --retry 3 -o "$TMP/$SZ_TARBALL" "$SZ_URL"
	echo "${SZ_SHA256}  ${TMP}/${SZ_TARBALL}" | shasum -a 256 -c -
	mkdir -p "$SRC"
	tar -xf "$TMP/$SZ_TARBALL" -C "$SRC"
	echo "[7z] extracted to $SRC"
fi

# ── apply local patches (idempotent — safe on an already-patched tree) ─────────
# Patch context lines are CRLF to match upstream sources; keep them that way.
PATCHED=0
for P in "$HERE"/patches/*.patch; do
	[ -e "$P" ] || continue
	if patch -p1 -d "$SRC" -N --dry-run < "$P" >/dev/null 2>&1; then
		echo "[7z] applying $(basename "$P")"
		patch -p1 -d "$SRC" -N < "$P"
		PATCHED=1
	elif patch -p1 -d "$SRC" -R --dry-run < "$P" >/dev/null 2>&1; then
		echo "[7z] $(basename "$P") already applied — skipping"
	else
		echo "[7z] ERROR: $(basename "$P") does not apply to 7-Zip ${SZ_VER}" >&2
		exit 1
	fi
done
# 7-Zip's makefiles have no header dependency tracking: after a fresh patch
# (which may touch headers) stale objects can mis-size structs and crash.
if [ "$PATCHED" = "1" ] && [ -d "$BUNDLE/b" ]; then
	echo "[7z] patches changed sources — cleaning previous objects"
	rm -rf "$BUNDLE/b"
fi

x86_asm_flag="USE_ASM="
command -v nasm >/dev/null 2>&1 && x86_asm_flag="USE_ASM=1"

echo "[7z] building arm64 (native asm)…"
( cd "$BUNDLE" && make -s -j"$JOBS" -f ../../cmpl_mac_arm64.mak )

echo "[7z] building x86_64 ($x86_asm_flag)…"
( cd "$BUNDLE" && make -s -j"$JOBS" -f ../../cmpl_mac_x64.mak $x86_asm_flag )

ARM="$BUNDLE/b/m_arm64/7z.so"
X64="$BUNDLE/b/m_x64/7z.so"
echo "[7z] lipo -> $HERE/7z.so"
lipo -create "$ARM" "$X64" -output "$HERE/7z.so"
lipo -info "$HERE/7z.so"
echo "[7z] done."
