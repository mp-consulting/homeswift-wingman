#!/bin/sh
# Packs "Homeswift Wingman.app" into a drag-to-Applications disk image (after apple-mail-mcp's make-dmg.sh).
#   Scripts/make-dmg.sh [app] [dmg]
#   defaults: ~/Library/Caches/HomeswiftWingman/dist/Homeswift Wingman.app -> …/dist/HomeswiftWingman.dmg
set -eu

CACHE="$HOME/Library/Caches/HomeswiftWingman"
APP="${1:-$CACHE/dist/Homeswift Wingman.app}"
DMG="${2:-$CACHE/dist/HomeswiftWingman.dmg}"
STAGE="$CACHE/dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Homeswift Wingman.app"
ln -s /Applications "$STAGE/Applications"

# hdiutil now and then fails with "Resource busy", so retry a few times.
for attempt in 1 2 3 4 5; do
    hdiutil create -volname "Homeswift Wingman" -srcfolder "$STAGE" -format UDZO -ov "$DMG" && break
    [ "$attempt" = 5 ] && exit 1
    sleep 5
done
# Match the app's Apple signing identity; the updater verifies the DMG before mounting it.
IDENTITY=$(codesign -d --verbose=4 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
[ -n "$IDENTITY" ] || { echo "The app must be signed before packaging updates." >&2; exit 1; }
codesign --force --sign "$IDENTITY" "$DMG"
codesign --verify --strict "$DMG"
rm -rf "$STAGE"
echo "Built $DMG"
