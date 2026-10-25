# Mac App Store and TestFlight

The AppStore configuration is the public-distribution build. It uses the same bundle ID
(com.mpconsulting.HomeswiftWingman), requires macOS 27.0.1 or later and compiles for Apple Silicon, enables App Sandbox with
incoming/outgoing networking, and excludes the GitHub updater code. Apple delivers updates.
Debug/Release remain development builds. No self-hosted runner is required for this route.

## Build and export

Install Xcode and XcodeGen, sign into the developer team in Xcode, then:

    BUILD_NUMBER=2 Scripts/app-store.sh
    BUILD_NUMBER=2 PROVISION=1 Scripts/app-store.sh export

Use a strictly increasing build number for each upload. PROVISION=1 permits Xcode to manage
provisioning. Export requires App Store distribution signing and a Mac App Store installer
certificate; Xcode Organizer can also manage distribution. The archive/export stay under
~/Library/Caches/HomeswiftWingman/AppStore. These commands do not upload or submit the app.

Create a macOS app record in App Store Connect with the explicit bundle ID above. Upload
using Xcode Organizer or Transporter, resolve validation/export-compliance questions, and
start internal TestFlight testing. External testing requires beta review; production requires
App Review. Do not claim approval or distribution readiness merely because the archive builds.

## Required validation on the distributed build

- Test Apple Silicon on macOS 27.0.1 or later; the deployment targets are in project.yml.
- Confirm the AppKit menu-bar bundle loads inside the sandbox and all tabs function.
- Grant HomeKit/local-network access; pair a throwaway bridge, read devices, change a test light,
  revoke pairing, and verify its pending requests are cancelled.
- Verify TLS keychain persistence and pairing storage after relaunch and upgrade.
- Sandbox storage differs from a non-sandboxed development install. Do not silently copy
  development pairing data; test migration explicitly or re-pair the bridge.
- Confirm login-item consent, listener retry, and port validation.
- Confirm Settings has no GitHub check/install controls.
- Inspect exported signing entitlements: HomeKit, sandbox and network access must remain;
  get-task-allow must not be enabled in distribution.
- Test on a Mac not registered for development using TestFlight.

## Privacy and review preparation

PrivacyInfo.xcprivacy declares app-only UserDefaults usage (CA92.1), no tracking, and no data
collected by the developer. Review App Store Connect's privacy answers against the final app
and bridge behavior: user-authorized Home data is transmitted locally to their paired bridge,
which may have its own cloud/AI integrations. Do not describe that downstream data flow as
universally local. Provide a public privacy-policy URL and accessible in-app privacy information
before submission. Declare encryption/export compliance accurately; Wingman uses TLS and
CryptoKit, so do not guess the exemption answer.

Suggested review description:

Wingman is a HomeKit companion for a user-owned Homeswift bridge. The user explicitly grants
Home access and pairs each bridge using a short-lived code. Connections use TLS and bridge
tokens. Users can revoke a bridge and disable accessory changes. Lock, garage-door and alarm
writes are blocked. The app lives in the menu bar and requires Home data for its core function.

Provide a reproducible review environment or a clearly identified synthetic demonstration
mode, review instructions, screenshots, support/privacy URLs, and beta contact information.
A reviewer must be able to assess functionality without access to the developer's private home.
These submission materials and App Store Connect setup still need to be completed.
