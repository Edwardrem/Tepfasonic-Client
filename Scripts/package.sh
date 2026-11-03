#!/bin/bash
# Packages a built Tepfasonic.app into a DMG (manual download) and a ZIP (Sparkle).
#   Scripts/package.sh path/to/Tepfasonic.app 0.2.0 dist
set -euo pipefail
APP="$1"; VERSION="$2"; OUT="${3:-dist}"
NAME="$(basename "$APP" .app)"
mkdir -p "$OUT"

ZIP="$OUT/$NAME-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

DMG="$OUT/$NAME-$VERSION.dmg"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"
echo "wrote $ZIP and $DMG"
