#!/bin/sh
# Regression tests compile the actual server and panel sources, with isolated storage and fake HomeKit data.
set -eu
cd "$(dirname "$0")/.."
BUILD=$(mktemp -d "${TMPDIR:-/tmp}/wingman-tests.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 App/Pairing.swift App/HTTPRequest.swift App/Identity.swift App/Settings.swift App/LocalServer.swift App/DemoStore.swift Tests/ServerTests.swift -o "$BUILD/server-tests"
"$BUILD/server-tests"
xcrun swiftc -parse-as-library -swift-version 6 MenuBar/StatusMenu.swift MenuBar/WingmanIcon.swift MenuBar/Update.swift MenuBar/Updater.swift Tests/PanelFixtures.swift Tests/PanelTests.swift -o "$BUILD/panel-tests"
"$BUILD/panel-tests" "${1:-$BUILD/snapshots}"
xcrun swiftc -parse-as-library -swift-version 6 -D APP_STORE MenuBar/StatusMenu.swift MenuBar/WingmanIcon.swift MenuBar/Update.swift MenuBar/Updater.swift Tests/PanelFixtures.swift Tests/PanelTests.swift -o "$BUILD/store-panel-tests"
"$BUILD/store-panel-tests" "$BUILD/store-snapshots"

xcrun swiftc -parse-as-library -swift-version 6 MenuBar/Update.swift Tests/UpdateTests.swift -o "$BUILD/update-tests"
"$BUILD/update-tests"
for script in Scripts/build.sh Scripts/release.sh Scripts/make-dmg.sh Scripts/test.sh Scripts/app-store.sh bin/dev; do
    sh -n "$script"
done
