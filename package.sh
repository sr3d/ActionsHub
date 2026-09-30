#!/bin/bash
# Builds ActionsHub.app and packages it into a distributable .dmg with a
# drag-to-Applications shortcut and the app icon as the volume / file icon.
# Everything lands in dist/.
#
#   ./package.sh                                     # native arch
#   ARCHS="arm64 x86_64" VERSION=1.0.0 ./package.sh  # universal (needs full Xcode)
set -euo pipefail

cd "$(dirname "$0")"

./build.sh

DIST="dist"
APP="$DIST/ActionsHub.app"
ICON="Icon/AppIcon.icns"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/ActionsHub-${VERSION}.dmg"

echo "==> Building disk image…"
# Create a blank image sized to the app and copy into it, rather than
# `hdiutil create -srcfolder`, which intermittently fails with "Resource busy".
RW="$(mktemp -u).dmg"
SIZE_MB=$(( $(du -sm "$APP" | cut -f1) + 20 ))
hdiutil create -size "${SIZE_MB}m" -fs HFS+ -volname "ActionsHub" -ov "$RW" >/dev/null
MOUNT="$(hdiutil attach "$RW" -nobrowse -noverify -readwrite | grep -o '/Volumes/.*' | head -1)"
trap 'hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; rm -f "$RW"' EXIT

ditto "$APP" "$MOUNT/ActionsHub.app"
ln -s /Applications "$MOUNT/Applications"
cp "$ICON" "$MOUNT/.VolumeIcon.icns"   # Finder uses this once the volume's icon bit is set
SetFile -a C "$MOUNT" || echo "    (warning: SetFile unavailable; volume icon not set)"

# Spotlight/Finder can briefly hold the fresh volume open; retry, then force.
for i in 1 2 3 4 5; do
    hdiutil detach "$MOUNT" >/dev/null 2>&1 && break
    sleep 2
    [ "$i" = 5 ] && hdiutil detach "$MOUNT" -force >/dev/null
done

echo "==> Compressing ${DMG}…"
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null

# Give the .dmg file itself the app icon in Finder.
swift Icon/set-file-icon.swift "$ICON" "$DMG" || echo "    (warning: could not set .dmg file icon)"

echo "==> Done: $(pwd)/$DMG"
