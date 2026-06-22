#!/bin/bash
#
# Build, sign, and package the standalone NextZip.app for distribution.
#
# Mirrors NppBeads/tools/build-release.sh:
#   - Universal Release build of the .app lands in   build-release/
#   - Signed DMG lands in                            downloads/
#   - tools/build-release.sh is the single entry point
#
# The dual app icon is rebuilt from source every run:
#   - resources/nzip.icon  → resources/Assets.car  (Tahoe 26+ Liquid Glass,
#     via Xcode's actool; CFBundleIconName=nzip)
#   - resources/nzip.icns  (Sequoia 15 and below;  CFBundleIconFile=nzip.icns)
#     is the hand-maintained classic icon — left as-is.
#
# Notarization is intentionally NOT in this script (needs Apple credentials);
# the summary prints the two commands to run after you've tested the DMG.
#
# Usage:
#   ./tools/build-release.sh
#   NO_ICON=1 ./tools/build-release.sh      # skip actool icon regen
#
# Environment variables (optional):
#   SIGNING_IDENTITY  - override signing identity (default: auto-detect
#                       Developer ID Application; ad-hoc "-" fallback)
#   ACTOOL            - override path to actool (default: auto-detect)
#   NO_ICON           - if set, don't regenerate Assets.car (use committed one)
#

set -e

# ── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build-release"
DOWNLOADS_DIR="$PROJECT_DIR/downloads"
ENTITLEMENTS="$PROJECT_DIR/shell-app/NextZip.entitlements"

APP_NAME="NextZip"
CMAKE_TARGET="NextZipApp"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Version from CMakeLists (single source of truth).
APP_VERSION=$(grep -E '^\s*set\s*\(\s*NEXTZIP_APP_VERSION\s+"' "$PROJECT_DIR/CMakeLists.txt" \
              | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
[ -z "$APP_VERSION" ] && APP_VERSION="1.0.0"

DMG_NAME="${APP_NAME}_${APP_VERSION}.dmg"
DMG_OUT="$DOWNLOADS_DIR/$DMG_NAME"

log()  { printf "\033[1;36m▶\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }

# Auto-detect Developer ID Application identity; ad-hoc fallback for local-only.
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
                       | grep "Developer ID Application" | head -1 \
                       | sed 's/.*"\(.*\)".*/\1/')
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    warn "No Developer ID Application certificate found — using ad-hoc signature."
    warn "The resulting DMG will only run on THIS Mac."
    SIGNING_IDENTITY="-"
fi

# ── 0. Regenerate the Tahoe Liquid Glass icon (resources/Assets.car) ─────────
#
# actool lives only inside a full Xcode (not the Command Line Tools). Try the
# usual places; if none is found, fall back to the committed Assets.car so the
# build still succeeds on a CLT-only machine.

if [ -z "$NO_ICON" ]; then
    if [ -z "$ACTOOL" ]; then
        ACTOOL=$(xcrun --find actool 2>/dev/null || true)
        for cand in \
            "/Volumes/XcodeSD/Xcode-26.3.app/Contents/Developer/usr/bin/actool" \
            "/Applications/Xcode.app/Contents/Developer/usr/bin/actool"; do
            [ -x "$ACTOOL" ] && break
            [ -x "$cand" ] && ACTOOL="$cand"
        done
    fi

    if [ -n "$ACTOOL" ] && [ -x "$ACTOOL" ] && [ -d "$PROJECT_DIR/resources/nzip.icon" ]; then
        log "Rebuilding resources/Assets.car from nzip.icon (actool)"
        CAR_TMP="/tmp/nzip_actool_$$"; rm -rf "$CAR_TMP"; mkdir -p "$CAR_TMP"
        "$ACTOOL" "$PROJECT_DIR/resources/nzip.icon" \
            --compile "$CAR_TMP" \
            --app-icon nzip \
            --output-partial-info-plist "$CAR_TMP/partial.plist" \
            --platform macosx \
            --minimum-deployment-target 11.0 \
            --target-device mac >/dev/null 2>&1 || warn "actool failed — keeping committed Assets.car"
        if [ -f "$CAR_TMP/Assets.car" ]; then
            cp -f "$CAR_TMP/Assets.car" "$PROJECT_DIR/resources/Assets.car"
            log "  → resources/Assets.car ($(du -h "$PROJECT_DIR/resources/Assets.car" | cut -f1))"
        fi
        rm -rf "$CAR_TMP"
    else
        warn "actool not found — using committed resources/Assets.car (Tahoe glass icon)."
    fi
fi
[ -f "$PROJECT_DIR/resources/nzip.icns" ] || warn "resources/nzip.icns missing — ≤Sequoia icon will be blank."

# ── 0b. Regenerate the DMG background (lavender drop zone + down arrow) ───────
#
# The Python generator owns the canonical icon-position constants; the
# AppleScript in step 3 mirrors them. Regenerating every run means nobody ships
# a stale background. Needs Pillow; if missing, fall back to the committed
# resources/dmg-background.tiff (or a plain layout if there isn't one).

if python3 -c "import PIL" >/dev/null 2>&1; then
    log "Regenerating DMG background (tools/generate-dmg-background.py)"
    /usr/bin/env python3 "$PROJECT_DIR/tools/generate-dmg-background.py" >/dev/null \
        || warn "DMG background generation failed — using committed dmg-background.tiff if present"
else
    warn "Pillow not installed — using committed resources/dmg-background.tiff if present."
fi

# ── 1. Build (Release, universal arm64+x86_64) ───────────────────────────────

log "Building $APP_NAME.app (Release, arm64+x86_64) → $BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# App target only; the plugin has its own build/ path.
cmake "$PROJECT_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DNEXTZIP_BUILD_PLUGIN=OFF \
    -DNEXTZIP_BUILD_APP=ON \
    >/dev/null

cmake --build . --target "$CMAKE_TARGET" --config Release -- -j"$(sysctl -n hw.ncpu)"

[ -d "$APP_BUNDLE" ] || err "Build did not produce $APP_BUNDLE"

log "Stripping debug + local symbols"
strip -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# ── 2. Codesign (inner-to-outer, hardened runtime) ───────────────────────────
#
# Sign the nested 7z.so engine first, then seal the app bundle with the
# entitlements. Hardened runtime + a secure timestamp are required for
# notarization. (No --deep: signing inner code explicitly is the supported way.)

log "Code-signing 7z.so + $APP_NAME.app (hardened runtime)"
if [ -f "$APP_BUNDLE/Contents/Resources/7z.so" ]; then
    codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$APP_BUNDLE/Contents/Resources/7z.so" 2>&1 | grep -vE "replacing existing signature$" || true
fi
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE" 2>&1 | grep -vE "replacing existing signature$" || true

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | tail -3

# ── 3. Build the DMG ─────────────────────────────────────────────────────────
#
# App + Applications symlink, icon-view layout. A custom background is used
# automatically if resources/dmg-background.tiff exists (bundled into the app's
# Resources so the DMG root stays clean); otherwise a plain icon layout.

log "Packaging $DMG_NAME → $DOWNLOADS_DIR"
mkdir -p "$DOWNLOADS_DIR"
rm -f "$DMG_OUT"

VOLUME_NAME="$APP_NAME"
MOUNT_POINT="/Volumes/$VOLUME_NAME"
DMG_TMP="/tmp/nextzip_dmg_rw_$$.dmg"
DMG_STAGE="/tmp/nextzip_dmg_stage_$$"
DMG_RESTAGE="/tmp/nextzip_dmg_restage_$$"

hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true

# The background TIFF is bundled at build time (CMake) and sealed by the step-2
# signature — reference it in place; never copy into the signed bundle (that
# would invalidate the signature).
HAVE_BG=""
[ -f "$APP_BUNDLE/Contents/Resources/dmg-background.tiff" ] && HAVE_BG=1

rm -rf "$DMG_STAGE" && mkdir -p "$DMG_STAGE"
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
STAGE_KB=$(du -sk "$DMG_STAGE" | awk '{print $1}')
DMG_SIZE_MB=$(( STAGE_KB / 1024 + 20 ))

hdiutil create \
    -srcfolder "$DMG_STAGE" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size ${DMG_SIZE_MB}m \
    "$DMG_TMP" >/dev/null

DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen \
         -mountpoint "$MOUNT_POINT" "$DMG_TMP" \
         | grep -E '^/dev/' | head -1 | awk '{print $1}')
ln -s /Applications "$MOUNT_POINT/Applications"

log "Setting DMG window layout"
/usr/bin/osascript <<DEFENSIVECLOSE >/dev/null 2>&1 || true
tell application "Finder"
    try
        close (every window whose target is disk "${VOLUME_NAME}")
    end try
end tell
DEFENSIVECLOSE

BG_LINE=""
[ -n "$HAVE_BG" ] && BG_LINE="set background picture of theViewOptions to file \"${APP_NAME}.app:Contents:Resources:dmg-background.tiff\""

/usr/bin/osascript <<APPLESCRIPT || true
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        tell container window
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set pathbar visible to false
            set sidebar width to 0
            set the bounds to {200, 120, 800, 800}
        end tell
        set theViewOptions to the icon view options of container window
        tell theViewOptions
            set arrangement to not arranged
            set icon size to 128
            set text size to 14
        end tell
        ${BG_LINE}
        -- Vertical layout (must match tools/generate-dmg-background.py):
        -- app icon centered near the top, Applications centered in the drop zone.
        set position of item "${APP_NAME}.app" of container window to {300, 130}
        set position of item "Applications" of container window to {300, 474}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sync
rm -rf "$MOUNT_POINT/.fseventsd" "$MOUNT_POINT/.Trashes" 2>/dev/null || true
chflags hidden "$MOUNT_POINT/.DS_Store" 2>/dev/null || true
sync

rm -rf "$DMG_RESTAGE" && mkdir -p "$DMG_RESTAGE"
/usr/bin/ditto "$MOUNT_POINT" "$DMG_RESTAGE"
hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$DEVICE" -force >/dev/null 2>&1

# Final compress: ULMO (lzma). Mounts on macOS 10.15+ (our min is 11.0).
# `hdiutil create` lays the image out; a follow-up `hdiutil convert` at
# lzma-level=9 re-packs the LZMA bands noticeably tighter (~4% smaller here —
# the level flag on `create` itself is a no-op). The convert preserves the
# .DS_Store layout, the Applications symlink, and chflags.
DMG_PRE="/tmp/nextzip_dmg_pre_$$.dmg"
rm -f "$DMG_PRE"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_RESTAGE" \
    -ov \
    -format ULMO \
    "$DMG_PRE" >/dev/null
hdiutil convert "$DMG_PRE" -format ULMO -imagekey lzma-level=9 -ov -o "$DMG_OUT" >/dev/null
rm -f "$DMG_PRE"

rm -f "$DMG_TMP"
rm -rf "$DMG_STAGE" "$DMG_RESTAGE"

# ── 4. Sign the DMG ──────────────────────────────────────────────────────────

log "Code-signing $DMG_NAME"
codesign --force --sign "$SIGNING_IDENTITY" "$DMG_OUT" 2>&1 | tail -2
codesign --verify --verbose=2 "$DMG_OUT" 2>&1 | tail -2

# ── 5. Summary ───────────────────────────────────────────────────────────────

APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
DMG_SIZE=$(du -sh "$DMG_OUT" | cut -f1)
DMG_SHA=$(shasum -a 256 "$DMG_OUT" | cut -d' ' -f1)

cat <<EOF

────────────────────────────────────────────────────────────────────
  $APP_NAME.app:    $APP_BUNDLE
                    $APP_SIZE, universal (arm64+x86_64)
  $APP_NAME DMG:    $DMG_OUT
                    $DMG_SIZE
  SHA-256:          $DMG_SHA
  Identity:         $SIGNING_IDENTITY
────────────────────────────────────────────────────────────────────

Next: test the DMG (double-click → drag $APP_NAME to Applications → launch).

For public release, after testing, notarize + staple the DMG:
  xcrun notarytool submit "$DMG_OUT" --keychain-profile NPP_NOTARIZE --wait
  xcrun stapler staple "$DMG_OUT"

If "Identity" above is "-" (ad-hoc), the DMG only works on this Mac.

EOF
