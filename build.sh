#!/bin/bash
# Builds ActionsHub.app from the SwiftPM executable. No Xcode required —
# just Command Line Tools (swift build) plus a hand-assembled .app bundle.
#
#     ./build.sh              # native arch → dist/ActionsHub.app
#     ./build.sh --install    # …and copy it to /Applications
#
# To build a universal binary (arm64 + x86_64, e.g. for a release) set ARCHS —
# this requires a full Xcode install, not just the Command Line Tools:
#
#     ARCHS="arm64 x86_64" ./build.sh
#
# VERSION sets CFBundleShortVersionString; in CI it comes from the git tag (v1.2.3 → 1.2.3).
set -euo pipefail

cd "$(dirname "$0")"

# Translate ARCHS ("arm64 x86_64") into repeated --arch flags. Empty = native.
ARCH_FLAGS=""
for a in ${ARCHS:-}; do ARCH_FLAGS="$ARCH_FLAGS --arch $a"; done

echo "==> Compiling (release)…"
swift build -c release $ARCH_FLAGS

APP="dist/ActionsHub.app"
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)/ActionsHub"

echo "==> Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ActionsHub"
cp Info.plist "$APP/Contents/Info.plist"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

VERSION="${VERSION:-}"
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
fi

# Ad-hoc sign so the app has a valid (if unverified) code signature.
echo "==> Ad-hoc signing…"
codesign --force --sign - "$APP"

echo "==> Done: $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/ActionsHub.app
    cp -R "$APP" /Applications/
    echo "    Installed to /Applications/ActionsHub.app"
else
    echo "    Launch with:  open $APP"
fi
