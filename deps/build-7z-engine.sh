#!/bin/bash
# Build the vendored 7-Zip engine (Format7zF: all formats + codecs) as a
# universal arm64+x86_64 shared library -> deps/7z.so. The NineZip plugin
# dlopen()s this at runtime and calls CreateObject / IInArchive / IOutArchive.
#
# arm64 uses the in-tree native assembly; x86_64 falls back to pure C unless
# NASM is installed (the .asm files are MASM/NASM dialect).
set -e
export PATH="/opt/homebrew/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$HERE/7zip/CPP/7zip/Bundles/Format7zF"
JOBS="$(sysctl -n hw.ncpu)"

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
