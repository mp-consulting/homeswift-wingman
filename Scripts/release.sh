#!/bin/sh
# Releases the version in project.yml (MARKETING_VERSION) from this Mac:
#   Scripts/release.sh
# builds the app signed in Release, packs HomeswiftWingman-<version>.dmg, tags v<version>, pushes the tag and
# creates the GitHub release with the image attached. The tap (mp-consulting/homebrew-tap, Casks/homeswift-wingman.rb)
# moves to it within 6 hours.
#
# It runs here, not in CI: HomeKit needs development signing (no Developer ID, no notarization, see the README),
# so the image is signed with this Mac's Apple Development certificate and its profile, and the app runs only on
# the Macs registered in the team's account.
set -eu
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^    MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)"
TAG="v$VERSION"
[ -n "$VERSION" ] || { echo "No MARKETING_VERSION in project.yml"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first"; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG exists already"; exit 1; }

CONFIGURATION=Release Scripts/build.sh
DIST="$HOME/Library/Caches/HomeswiftWingman/dist"
DMG="$DIST/HomeswiftWingman-$VERSION.dmg"
Scripts/make-dmg.sh "$DIST/Homeswift Wingman.app" "$DMG"

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
cat > "$NOTES" <<NOTES
Homeswift Wingman $VERSION.

\`brew install --cask mp-consulting/tap/homeswift-wingman\`, or open the disk image and drag the app to Applications.

The app is signed for development (HomeKit is not available to Developer ID apps), so it runs only on the Macs
registered in the developer's team, and macOS asks once before opening it: System Settings › Privacy & Security ›
Open Anyway.
NOTES

git tag -a "$TAG" -m "Homeswift Wingman $VERSION"
git push origin "$TAG"
gh release create "$TAG" "$DMG" --title "$VERSION" --notes-file "$NOTES" --verify-tag
echo "Released $TAG: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
