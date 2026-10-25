# Homeswift Sidecar (spike)

A menu bar app that reads the Home app's homes, rooms, zones, scenes and accessories through Apple's HomeKit
framework, and serves them as JSON on `127.0.0.1:8619` for a Homeswift plugin to read. HomeKit exists on the Mac
only for Mac Catalyst apps (the Home app is one), so this is a Catalyst app; its menu bar item lives in an AppKit
bundle (`MenuBar/`, loaded from `Contents/PlugIns`), because a Catalyst app cannot make an `NSStatusItem` itself.

```sh
Scripts/build.sh --unsigned          # compile only
PROVISION=1 Scripts/build.sh         # first signed build: Xcode registers the App ID, this Mac and a development profile
Scripts/build.sh --install           # ~/Applications/Homeswift Sidecar.app, launched
curl -s 127.0.0.1:8619/status        # authorization, counts, events received, last read
curl -s 127.0.0.1:8619/homes         # homes → rooms, zones, scenes, accessories → services → characteristics
curl -s 127.0.0.1:8619/events        # the latest 200 value changes HomeKit pushed, with the app's state at the time
curl -s -X POST 127.0.0.1:8619/read  # reads every readable value; failures grouped by error
```

`SIDECAR_PORT` changes the port. Launch it with `open` (or from Finder): started from a shell, macOS checks the
shell's Info.plist for the HomeKit usage text and kills the app.

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

Writing values, a token on the local API (any process of the user can read it now), a login item, Homeswift's
side (a plugin that reads `/homes` and `/events`), and Linux, which has no HomeKit.
