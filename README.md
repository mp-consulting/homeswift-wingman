# Homeswift Wingman (spike)

A menu bar app that reads the Home app's homes, rooms, zones, scenes and accessories through Apple's HomeKit
framework, and serves them as JSON over TLS to the Homeswift bridges paired with it, on any machine of the network.
It rides alongside the bridge, hence the name. HomeKit exists on the Mac only for Mac Catalyst apps (the Home app is
one), so this is a Catalyst app; its menu bar item lives in an AppKit bundle (`MenuBar/`, loaded from
`Contents/PlugIns`), because a Catalyst app cannot make an `NSStatusItem` itself.

```sh
Scripts/build.sh --unsigned          # compile only (an unsigned build has no keychain, so it serves nothing)
PROVISION=1 Scripts/build.sh         # first signed build: Xcode registers the App ID, this Mac and a development profile
Scripts/build.sh --install           # ~/Applications/Homeswift Wingman.app, launched
dns-sd -B _homeswift-wingman._tcp    # Bonjour: the instance, with v, id and home in its TXT record
curl -sk https://127.0.0.1:8619/info # id, version, certificate fingerprint, whether pairing is open
# Menu → Pair a Homeswift Bridge… shows a six-digit code for ten minutes:
curl -sk https://127.0.0.1:8619/pair -d '{"code": "123456", "name": "My bridge"}'   # → {"token", …}
H="Authorization: Bearer <token>"
curl -sk -H "$H" https://127.0.0.1:8619/status        # authorization, counts, events received, last read
curl -sk -H "$H" https://127.0.0.1:8619/homes         # homes → rooms, zones, scenes, accessories → services → characteristics
curl -sk -H "$H" https://127.0.0.1:8619/events        # the latest 200 value changes HomeKit pushed
curl -sk -H "$H" -X POST https://127.0.0.1:8619/read  # reads every readable value; failures grouped by error
```

The menu bar item (a bird) shows the headline, the homes and the pairing code; Open Wingman… (⌘,) opens its window,
after apple-mail-mcp's menu bar panel: SwiftUI with Liquid Glass on macOS 26, three tabs (Home: rooms and accessories,
Read All; Bridges: the pairing code, the paired bridges, the certificate; Settings: Bonjour, the port, whether bridges
may change accessories, open at login). The window is the Catalyst side's: SwiftUI cannot run in the AppKit bundle,
because a Catalyst process loads the iOS SwiftUI. `open "Homeswift Wingman.app" --args --snapshot DIR` draws each tab
to PNG, dark and light, then quits.

The settings live in the app's user defaults; `WINGMAN_PORT` wins over the port setting. Launch it with `open` (or from Finder): started from a shell, macOS checks the
shell's Info.plist for the HomeKit usage text and kills the app.

## Discovery, TLS and pairing

- **Bonjour:** `_homeswift-wingman._tcp` on every interface, named after the Mac. The TXT record has `v` (the API
  version, `1`), `id` (Wingman's, made once) and `home` (16 hex digits of the SHA-256 of the homes' identifiers), so
  a bridge that finds Wingman on two Macs of the same home keeps one. Nothing else: anyone on the network reads it.
- **TLS:** a P-256 key and a self-signed certificate made at the first launch and kept in the data protection
  keychain (label "Homeswift Wingman TLS"). It names nothing and lasts until 2049: the bridge pins its SHA-256 when it
  pairs (Homeswift's `HTTPClient` trust `.pinned`), and a new certificate would unpair every bridge. The menu shows the
  start of the fingerprint under Paired Bridges, to compare with what the bridge shows.
- **Pairing:** Pair a Homeswift Bridge… shows a six-digit code for ten minutes. `POST /pair` with it returns a token
  (32 random bytes); the code serves once and five wrong ones close the pairing. Every route but `/info` and `/pair`
  needs `Authorization: Bearer <token>`. Only each token's SHA-256 is kept, with the bridge's name and when it was
  last seen, in `~/Library/Application Support/com.mpconsulting.HomeswiftWingman/bridges.json` (owner only). The menu
  removes a bridge.
- **What pairing trusts:** the code goes over TLS to a certificate the bridge has not seen yet, so someone who sits
  between the two on the network during those ten minutes could pair in the bridge's place. After pairing the
  certificate is pinned. HAP closes that gap with SRP; a later version could too, or the bridge can show the
  fingerprint to compare with the menu.

## Install

```sh
brew install --cask mp-consulting/tap/homeswift-wingman
```

Releases are made on a Mac with the team's development certificate: `Scripts/release.sh` builds the version in
`project.yml` signed, packs `HomeswiftWingman-<version>.dmg`, tags it and creates the GitHub release; the tap's
cask follows within 6 hours. The image runs only on the Macs registered in the team's account (below), and macOS
asks once before opening it (System Settings › Privacy & Security › Open Anyway).

## Signing: no Developer ID, no notarization

Apple's "Supported capabilities (macOS)" table lists HomeKit for the Apple Developer Program (development and
App Store) only, not for Developer ID. So the apple-mail-mcp process (Developer ID, notarized DMG, Homebrew cask)
cannot ship this app with HomeKit. The ways out:

- **Development signing** (this spike): runs on Macs registered in the team's account, with a development profile
  that expires every year. Fine for one's own bridge Mac, not for other people.
- **Mac App Store or TestFlight for Mac**: needs the App Sandbox (`com.apple.security.network.server` for the local
  server) and App Review.

## Findings (2026-10-25, macOS 27, one home)

- **Provisioning:** `xcodebuild -allowProvisioningUpdates` registered this Mac and made a wildcard Mac Catalyst profile, but
  would not turn HomeKit on for the App ID ("Entitlement com.apple.developer.homekit not found"), even with
  `SystemCapabilities` in the project. Opening the project in Xcode once did it; command line builds work since.
- **Permission:** the prompt is per signature: the ad-hoc test copy and the development build each asked.
- **Homes:** 1 home, 19 rooms, 2 zones, 40 scenes, 120 accessories (114 bridged), 361 services, 1,523
  characteristics, all with their room. Bridged accessories report the category "Other"; their services say what
  they are. Homeswift's own accessories are there (manufacturer per plugin, bridged), so a plugin must skip them.
- **Reading every value** (`POST /read`): 1,383 readable characteristics in under a second; 1,107 read, 276 failed
  with `HMErrorDomain 74` ("Read/Write operation failed"). The failures are exactly the 66 **Matter** accessories
  (`"matter": true`: a service with a `matterEndpointID`): the Hue bridge and its lights and sensors, IKEA DIRIGERA
  and its devices, the Nuki lock, and 41 bridged ones reporting manufacturer "Unknown". All 54 HAP accessories read
  fine, Homeswift's included. Half of the Matter characteristics still have a cached value. `matterNodeID` is no
  test: every accessory has one, HAP ones too.
- **Events:** value changes arrive, from Matter accessories too (Hue lights and sensors): notifications work
  where reads fail. The app reports `active` the whole time, as a menu bar app: no background state so far.
- **Writing** (`POST /write`): a Matter ceiling light took hue 0 and saturation 100 in about 0.07 s, although every
  read of it fails. Two Matter lamps switched off at the wall refused with the same `HMErrorDomain 74` in 30–40 ms,
  while HomeKit still listed them as reachable: for Matter devices `reachable` lags, and error 74 on a write means
  the device did not answer. No event came back from the light after the write; HomeKit's value is the one written.
  Lock, garage door and alarm targets are refused before HomeKit is asked.
- **Soak test:** `/status` has `startedAt`, `lastEventAt` and `eventsPerHour` (UTC hours); a gap across a night of
  screen lock and sleep would show HomeKit stopped sending.

## What the spike has to answer

- Does a menu bar (`LSUIElement`) Catalyst app get HomeKit's permission prompt, and its homes, at all?
- Does HomeKit keep sending value changes (`/events`, `appState`) when the app has no window and is not frontmost?
  On iOS, HomeKit stops apps in the background; the Home app itself carries
  `com.apple.developer.homekit.background-mode`, which developers cannot request.
- Can it read every value (`POST /read`) from the background, and how long does it take on a real home?
- Do bridged accessories (Homeswift's own) appear, so a plugin can skip them and avoid showing them twice?
- Does it keep running after login, screen lock and sleep (`NSSupportsAutomaticTermination` is off)?

## Not in the spike

A login item, Homeswift's side (a plugin that finds Wingman over Bonjour, pairs, reads `/homes` and `/events`), a
password-authenticated pairing (SRP), and Linux, which has no HomeKit.
