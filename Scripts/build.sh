#!/bin/sh
# Builds "Homeswift Wingman.app" (Mac Catalyst) from project.yml with XcodeGen and xcodebuild.
#   Scripts/build.sh               -> ~/Library/Caches/HomeswiftWingman/dist/Homeswift Wingman.app
#   Scripts/build.sh --install     -> also copies it to ~/Applications and relaunches it
#   Scripts/build.sh --unsigned    -> compile only, no signing (the app cannot use HomeKit then)
# Signing is Xcode's automatic signing with an Apple Development certificate: HomeKit is an ADP-only capability
# (developer.apple.com, "Supported capabilities (macOS)"), so a Developer ID build cannot carry it and a
# notarized Developer ID app has no HomeKit. PROVISION=1 lets Xcode register the App ID, this Mac and the
# development profile on the team's account (-allowProvisioningUpdates).
# Build output lives outside the repo: files in Documents carry Finder metadata, which codesign refuses.
set -eu
cd "$(dirname "$0")/.."

CACHE="$HOME/Library/Caches/HomeswiftWingman"
APP="$CACHE/dist/Homeswift Wingman.app"

xcodegen generate --quiet
# XcodeGen writes nested target attributes as a quoted string; Xcode reads SystemCapabilities only as a dictionary.
sed -i '' 's/SystemCapabilities = ".*";/SystemCapabilities = { com.apple.HomeKit = { enabled = 1; }; };/' \
    HomeswiftWingman.xcodeproj/project.pbxproj

SIGNING=""
case "${1:-}" in
--unsigned) SIGNING="CODE_SIGNING_ALLOWED=NO" ;;
esac
PROVISIONING=""
[ "${PROVISION:-}" = 1 ] && PROVISIONING="-allowProvisioningUpdates -allowProvisioningDeviceRegistration"

xcodebuild -project HomeswiftWingman.xcodeproj -scheme HomeswiftWingman -configuration "${CONFIGURATION:-Debug}" \
    -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$CACHE/build" $PROVISIONING \
    $SIGNING -quiet build

BUILT="$CACHE/build/Build/Products/${CONFIGURATION:-Debug}-maccatalyst/HomeswiftWingman.app"
rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
ditto "$BUILT" "$APP"
[ -n "$SIGNING" ] || codesign --verify --strict --deep "$APP"
echo "Built $APP"
[ -n "$SIGNING" ] || codesign -d --entitlements :- "$APP" 2>/dev/null | grep -A1 homekit || true

if [ "${1:-}" = "--install" ]; then
    DEST="$HOME/Applications/Homeswift Wingman.app"
    pkill -x HomeswiftWingman 2>/dev/null && sleep 1 || true
    mkdir -p "$HOME/Applications"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "Installed and launched $DEST"
fi
