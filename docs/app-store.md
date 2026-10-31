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
writes are blocked unless the user turns on "Let bridges operate locks and doors" (off by default). The app lives in the menu bar and requires Home data for its core function.

A reviewer must be able to assess functionality without access to the developer's private home, so Wingman has a
demo mode (see the README). Suggested App Review notes:

    Wingman is a menu bar app: after launch, click the winged-house icon in the menu bar.
    No HomeKit accessories or Homeswift bridge are needed to review it.
    1. Allow Home access when asked (or decline: Wingman then offers the demo).
    2. Home tab: click "Try Demo Mode", or turn on Settings > Demo mode. A synthetic
       "Demo Home (Synthetic)" appears, marked DEMO MODE.
    3. Bridges tab: click "Pair Demo Bridge". A built-in demo bridge pairs over TLS with
       a one-time code, reads the home, switches "Demo Floor Lamp" and is refused an unlock,
       showing each step. The lamp's new state shows in the Home tab.
    4. Click "Remove…" next to "Demo Bridge (Synthetic)" to revoke it, then "Pair Demo
       Bridge" again: its old token is rejected before it pairs anew.
    5. Settings: "Let bridges change accessories" off makes bridges read-only; the demo
       bridge then reports its lamp change refused.
    Demo mode never reads or changes HomeKit data. Turn it off in Settings.

    Network server entitlement: Wingman listens for incoming connections, which is its
    core function. It serves the user's Apple Home to Homeswift bridges on their local
    network: an NWListener on TCP port 8619 (configurable in Settings), TLS 1.2 or later
    with an on-device certificate, advertised over Bonjour as _homeswift-wingman._tcp
    (hence NSLocalNetworkUsageDescription). Bridges connect to Wingman, pair with a
    one-time code and then use a revocable token, so network.client alone is not enough.
    The demo bridge in step 3 connects to this same listener.

Build 0.2.0 (7) was rejected under 2.4.5 by an automated check that flagged `com.apple.security.network.server` as
unused. Keep the paragraph above in the App Review notes, and reply with it if the check fires again: the entitlement
is needed by `LocalServer`, so do not remove it.

Still to complete in App Store Connect: screenshots (demo mode is safe to capture), support and privacy URLs,
and beta contact information.
