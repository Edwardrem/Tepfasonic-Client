#!/bin/bash
# Packages a built Tepfasonic.app into a DMG (manual download) and a ZIP (Sparkle).
#   Scripts/package.sh path/to/Tepfasonic.app 0.2.0 dist
set -euo pipefail
APP="$1"; VERSION="$2"; OUT="${3:-dist}"
NAME="$(basename "$APP" .app)"
mkdir -p "$OUT"

# Work on a clean copy: extended attributes picked up from an iCloud-synced or
# Finder-touched checkout (com.apple.FinderInfo, com.apple.fileprovider.*) are
# "detritus" to codesign, and a bundle carrying them fails validation at launch.
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
xattr -cr "$STAGING/$NAME.app"
codesign --verify --deep --strict "$STAGING/$NAME.app"

ZIP="$OUT/$NAME-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent --norsrc --noextattr "$STAGING/$NAME.app" "$ZIP"

DMG="$OUT/$NAME-$VERSION.dmg"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"
echo "wrote $ZIP and $DMG"
