#!/bin/sh
# Build an App Store archive; export for Transporter with: BUILD_NUMBER=2 Scripts/app-store.sh export
set -eu
cd "$(dirname "$0")/.."
MODE=${1:-archive}
case "$MODE" in archive|export) ;; *) echo "Usage: BUILD_NUMBER=<increasing integer> Scripts/app-store.sh [archive|export]" >&2; exit 1 ;; esac
case "${BUILD_NUMBER:-}" in ''|*[!0-9]*|0) echo "Set BUILD_NUMBER to a positive, increasing integer." >&2; exit 1 ;; esac
CACHE="$HOME/Library/Caches/HomeswiftWingman"
# Stage outside Documents, generate the project and validate the App Store configuration first.
CONFIGURATION=AppStore bin/dev build
ARCHIVE="$CACHE/AppStore/HomeswiftWingman.xcarchive"
mkdir -p "$CACHE/AppStore"
set -- -project "$CACHE/source/HomeswiftWingman.xcodeproj" -scheme HomeswiftWingman \
    -configuration AppStore -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -archivePath "$ARCHIVE" -derivedDataPath "$CACHE/build" \
    "CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
if [ "${PROVISION:-}" = 1 ]; then set -- "$@" -allowProvisioningUpdates; fi
xcodebuild "$@" archive
echo "Archive: $ARCHIVE"
if [ "$MODE" = export ]; then
    set -- -exportArchive -archivePath "$ARCHIVE" -exportPath "$CACHE/AppStore/export" \
        -exportOptionsPlist Scripts/AppStoreExportOptions.plist
    if [ "${PROVISION:-}" = 1 ]; then set -- "$@" -allowProvisioningUpdates; fi
    xcodebuild "$@"
    echo "Export: $CACHE/AppStore/export (upload with Transporter or Xcode Organizer)"
fi
