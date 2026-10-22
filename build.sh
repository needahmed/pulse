#!/bin/bash
# Builds Pulse.app from source.
#
#   ./build.sh                  build for this Mac
#   ./build.sh --universal      build one app that runs on Apple Silicon and Intel
#   ./build.sh --install        build, copy to /Applications and launch
#
# Optional environment:
#   VERSION=1.2.0                                           version written into Info.plist
#   SIGN_IDENTITY="Developer ID Application: Name (TEAM)"   real signing (default is ad hoc)
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

VERSION="${VERSION:-1.0.0}"
VERSION="${VERSION#v}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install the command line tools first:"
  echo "  xcode-select --install"
  exit 1
fi

APP="Pulse.app"
BIN="$APP/Contents/MacOS/Pulse"
rm -rf build "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {
  echo "Compiling for $1..."
  xcrun -sdk macosx swiftc \
    -O -swift-version 5 -parse-as-library \
    -target "$1-apple-macos13.0" \
    -framework SwiftUI -framework AppKit -framework IOKit -framework ServiceManagement \
    Sources/*.swift \
    -o "$2"
}

if [ "$UNIVERSAL" = 1 ]; then
  compile arm64 build/Pulse-arm64
  compile x86_64 build/Pulse-x86_64
  lipo -create build/Pulse-arm64 build/Pulse-x86_64 -output "$BIN"
else
  compile "$(uname -m)" "$BIN"
fi

cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

if [ -f Resources/AppIcon.png ]; then
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - "$APP"
  echo "Signed ad hoc (fine for your own Mac, downloads will hit Gatekeeper)"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
  echo "Signed with $SIGN_IDENTITY"
fi

echo "Built $(pwd)/$APP  (version $VERSION)"

if [ "$INSTALL" = 1 ]; then
  pkill -x Pulse 2>/dev/null || true
  rm -rf "/Applications/$APP"
  ditto "$APP" "/Applications/$APP"
  open "/Applications/$APP"
  echo "Installed to /Applications and launched. Look for it in your menu bar."
fi
