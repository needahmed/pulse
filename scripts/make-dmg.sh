#!/bin/bash
# Packages Pulse.app into a drag to install DMG at dist/Pulse-<version>.dmg
#
#   ./build.sh --universal && scripts/make-dmg.sh 1.0.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-${VERSION:-1.0.0}}"
VERSION="${VERSION#v}"
APP="Pulse.app"

if [ ! -d "$APP" ]; then
  echo "Pulse.app not found. Build it first: ./build.sh --universal"
  exit 1
fi

mkdir -p dist
DMG="dist/Pulse-$VERSION.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/$APP"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"

# hdiutil occasionally fails with "Resource busy" on CI machines, so retry a few times.
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname "Pulse" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null; then
    break
  fi
  if [ "$attempt" = 5 ]; then
    echo "hdiutil failed"
    exit 1
  fi
  echo "hdiutil busy, retrying..."
  sleep 3
done

if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

echo "Created $DMG"
